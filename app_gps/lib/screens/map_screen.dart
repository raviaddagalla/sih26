import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter, FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart' show HapticFeedback, rootBundle;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/navigation_models.dart';
import '../services/location_service.dart';
import '../services/route_service.dart';
import '../services/session_logger.dart';
import '../widgets/navigation_panel.dart';
import '../widgets/ios_button.dart';
import '../services/geocoding_service.dart';
import '../widgets/location_picker.dart';
import '../widgets/telemetry_hud.dart';
import '../widgets/demo_control_panel.dart';
import '../widgets/google_maps_puck.dart';
import '../widgets/stealth_settings_dialog.dart';
import '../idr_engine/idr_engine.dart';
import '../idr_engine/core/nav_telemetry.dart';
import '../idr_engine/core/gnss_sample.dart';
import '../adapters/android_sensor_adapter.dart';
import '../adapters/dataset_replay_adapter.dart';
import '../idr_engine/fusion/vehicle_profile.dart';
import '../idr_engine/fusion/gnss_integrity_monitor.dart';
import '../services/cached_tile_provider.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final _mapController = MapController();
  final _location = LocationService();
  final _routes = RouteService();
  final SessionLogger _logger = SessionLogger();

  // IDR Navigation Master Engine & Adapters
  final IdrEngine _idrEngine = IdrEngine();
  late final AndroidSensorAdapter _liveSensorAdapter;
  final DatasetReplayAdapter _replayAdapter = DatasetReplayAdapter();

  StreamSubscription<LatLng>? _locationSubscription;
  StreamSubscription<NavigationTelemetry>? _telemetrySubscription;
  StreamSubscription<GnssSample>? _rawGnssSubscription;

  NavigationState _state = const NavigationState();
  final ValueNotifier<NavigationTelemetry?> _telemetryNotifier =
      ValueNotifier<NavigationTelemetry?>(null);
  String? _message;

  bool _isDemoMode = false;
  bool _isHudVisible = true;
  double _vehicleHeading = 0.0;
  bool _isHeadingUp = true;
  bool _isUserDragging = false;
  bool _isRerouting = false;
  DateTime? _lastRerouteAttempt;
  bool _dismissedCalibrationNotice = false;
  RouteData? _cachedRoute;

  // Smooth marker/camera glide: interpolates the 10 Hz telemetry ticks so the
  // vehicle icon and camera move continuously instead of snapping every 100ms.
  late final AnimationController _markerAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  Tween<double>? _latTween, _lngTween, _headingTween;
  double? _renderLat, _renderLng, _renderHeading;

  // Sliced route points for polyline rendering
  List<LatLng> _traveledPoints = [];
  List<LatLng> _remainingPoints = [];

  /// Restarts the glide animation from wherever the marker currently is
  /// (not from the raw telemetry value) so back-to-back ticks compose into
  /// one continuous motion rather than a stutter-step.
  void _updateMarkerAnimation(double lat, double lng, double headingDeg) {
    final curLat = _renderLat ?? lat;
    final curLng = _renderLng ?? lng;
    final curHeading = _renderHeading ?? headingDeg;

    // Shortest-path heading interpolation so 359°→2° doesn't spin the long way.
    final headingDelta = ((headingDeg - curHeading + 540) % 360) - 180;
    final targetHeading = curHeading + headingDelta;

    _latTween = Tween(begin: curLat, end: lat);
    _lngTween = Tween(begin: curLng, end: lng);
    _headingTween = Tween(begin: curHeading, end: targetHeading);

    _markerAnim
      ..stop()
      ..value = 0.0
      ..forward();
  }

  /// Called on every animation frame (~60 fps) while a glide is in progress.
  /// Drives both the rendered marker position/heading and the camera pan so
  /// they move in lockstep instead of the camera jumping once per tick.
  void _onMarkerAnimTick() {
    if (_latTween == null) return;
    _renderLat = _latTween!.evaluate(_markerAnim);
    _renderLng = _lngTween!.evaluate(_markerAnim);
    _renderHeading = (_headingTween!.evaluate(_markerAnim)) % 360;

    final isNavigating = _state.isNavigating || _isDemoMode;
    if (isNavigating && !_isUserDragging) {
      final pos = LatLng(_renderLat!, _renderLng!);
      if (_isHeadingUp) {
        _mapController.moveAndRotate(
          pos,
          _mapController.camera.zoom.clamp(15.5, 18.0),
          -_renderHeading!,
        );
      } else {
        _mapController.move(pos, _mapController.camera.zoom);
      }
    }
  }

  @override
  void initState() {
    super.initState();

    CachedTileProvider.init();
    _markerAnim.addListener(_onMarkerAnimTick);

    // Share the unified LocationService with AndroidSensorAdapter
    _liveSensorAdapter = AndroidSensorAdapter(locationService: _location);

    // 1. Initialize the IDR Engine
    _idrEngine.initialize();

    // Load offline road network map database for general road-network matching
    rootBundle.loadString('assets/data/road_network_demo.json').then((jsonStr) {
      _idrEngine.loadRoadNetworkJson(jsonStr);
    }).catchError((_) {});

    // 2. Subscribe to 10 Hz IDR Engine Telemetry Output
    _telemetrySubscription = _idrEngine.telemetryStream.listen((telemetry) {
      if (!mounted) return;
      final newPos = LatLng(telemetry.latitude, telemetry.longitude);

      // Log high-rate telemetry to active on-device session file for post-drive plotting
      if (_logger.isLogging) {
        _logger.logTelemetry(telemetry);
      }

      // High-frequency tier: update telemetry ValueNotifier and vehicle glide
      _telemetryNotifier.value = telemetry;
      _vehicleHeading = telemetry.heading;
      _updateMarkerAnimation(telemetry.latitude, telemetry.longitude, telemetry.heading);

      // Route polyline slicing (statically typed without dynamic casts)
      if (telemetry.slicedRoutePoints != null && _state.route != null) {
        _remainingPoints = telemetry.slicedRoutePoints!;
        final routePoints = _state.route!.points;
        final segIdx = telemetry.currentSegmentIndex;
        _traveledPoints = routePoints.sublist(0, min(segIdx + 1, routePoints.length));
        _traveledPoints.add(newPos);
      }

      // Low-frequency tier: Step index & maneuver distance tracking
      int stepIdx = _state.currentStepIndex;
      double distNext = _state.distanceToNextStepMeters;
      if (_state.route != null && _state.route!.steps.isNotEmpty) {
        stepIdx = _findCurrentStepIndex(newPos, _state.route!);
        if (stepIdx < _state.route!.steps.length - 1) {
          final stepLoc = _state.route!.steps[stepIdx].location;
          if (stepLoc != null) {
            distNext = _haversineMeters(
              newPos.latitude, newPos.longitude,
              stepLoc.latitude, stepLoc.longitude,
            );
          }
        }
      }

      // Frequency tiering guard: Only invoke setState when low-frequency route state changes!
      final bool stepChanged = stepIdx != _state.currentStepIndex;
      final bool offRouteChanged = telemetry.isOffRoute != _state.isOffRoute;
      final bool distChanged = (_state.distanceToNextStepMeters - distNext).abs() > 25.0;

      if (stepChanged || offRouteChanged || distChanged) {
        setState(() {
          _state = _state.copyWith(
            userLocation: newPos,
            currentStepIndex: stepIdx,
            distanceToNextStepMeters: distNext,
            remainingDistanceMeters: telemetry.remainingDistanceMeters,
            isOffRoute: telemetry.isOffRoute,
          );
        });
      } else {
        // Update userLocation and remainingDistance in _state without triggering full-screen setState
        _state = _state.copyWith(
          userLocation: newPos,
          distanceToNextStepMeters: distNext,
          remainingDistanceMeters: telemetry.remainingDistanceMeters,
        );
      }

      // Auto-reroute if off-route for extended time (throttled to 15s to prevent network spin in tunnels)
      if (telemetry.isOffRoute && !_isRerouting && !_isDemoMode && _state.destination != null) {
        final now = DateTime.now();
        if (_lastRerouteAttempt == null || now.difference(_lastRerouteAttempt!).inSeconds >= 15) {
          _lastRerouteAttempt = now;
          _autoReroute();
        }
      }
    });

    // 3. Fallback Location subscription when not navigating with IDR
    _locationSubscription = _location.updates.listen((point) {
      if (!mounted || _idrEngine.isRunning) return;
      setState(() => _state = _state.copyWith(userLocation: point));
    });

    _startLiveLocation();
  }

  int _findCurrentStepIndex(LatLng pos, RouteData route) {
    if (route.steps.isEmpty) return 0;
    int best = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < route.steps.length; i++) {
      final loc = route.steps[i].location;
      if (loc == null) continue;
      final d = _haversineMeters(pos.latitude, pos.longitude, loc.latitude, loc.longitude);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    // If we're very close to step N, show step N+1 as upcoming
    if (bestDist < 30.0 && best < route.steps.length - 1) {
      return best + 1;
    }
    return best;
  }

  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const R = 6378137.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }

  Future<void> _autoReroute() async {
    if (_isRerouting || _state.destination == null || _state.userLocation == null) return;
    _isRerouting = true;
    try {
      final route = await _routes.calculate(start: _state.userLocation!, end: _state.destination!);
      if (!mounted) return;
      _cachedRoute = route;
      setState(() {
        _state = _state.copyWith(route: route, isOffRoute: false);
        _traveledPoints = [];
        _remainingPoints = route.points;
      });
      _idrEngine.setRoute(route.points);
    } catch (_) {
      // Retain _cachedRoute and existing polyline when offline in a tunnel or underground structure
      if (_cachedRoute != null && _state.route == null) {
        setState(() => _state = _state.copyWith(route: _cachedRoute));
      }
    } finally {
      _isRerouting = false;
    }
  }

  Future<void> _startLiveLocation() async {
    setState(() => _message = 'Acquiring initial GNSS fix…');
    try {
      final access = await _location.requestAccess();
      if (!mounted) return;
      if (access == LocationAccess.permissionDenied) {
        setState(() => _message = 'Location permission is denied. Allow it in Android Settings to continue.');
        return;
      }
      if (access == LocationAccess.serviceDisabled) {
        setState(() => _message = 'Location services are off. Turn on GPS and tap retry.');
        return;
      }
      _location.start();
      final point = await _location.getCurrent();
      if (!mounted) return;
      if (point != null) {
        setState(() {
          _message = null;
          _state = _state.copyWith(userLocation: point);
        });
        _mapController.move(point, 15);
      } else {
        setState(() => _message = 'GPS is on, waiting for satellite fix. Move outdoors if indoors.');
      }
    } catch (_) {
      if (mounted) setState(() => _message = 'Unable to access GPS. Check Settings and retry.');
    }
  }

  Future<void> _selectDestination(PlaceSuggestion suggestion) async {
    final start = _state.userLocation;
    if (start == null) {
      setState(() => _message = 'Waiting for initial GPS location.');
      return;
    }
    setState(() => _message = 'Calculating optimal route with OSRM…');
    try {
      final route = await _routes.calculate(start: start, end: suggestion.point);
      if (!mounted) return;
      setState(() {
        _message = null;
        _state = _state.copyWith(destination: suggestion.point, route: route);
        _traveledPoints = [];
        _remainingPoints = route.points;
      });
      _idrEngine.setRoute(route.points);
      _fitRoute(route.points);
      CachedTileProvider.precacheRoute(route.points);
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not calculate route. Check internet connection.');
    }
  }

  void _fitRoute(List<LatLng> points) {
    if (points.isEmpty) return;
    final bounds = LatLngBounds.fromPoints(points);
    _mapController.fitCamera(CameraFit.bounds(
      bounds: bounds,
      padding: const EdgeInsets.fromLTRB(50, 180, 50, 330),
    ));
  }

  /// Starts live dead reckoning navigation using phone IMU + GNSS
  Future<void> _startLiveNavigation() async {
    if (_state.route == null) return;
    final startPoint = _state.userLocation ?? _state.route!.points.first;

    // Cache active route so offline tunnel driving never drops polyline/guidance
    _cachedRoute = _state.route;
    _dismissedCalibrationNotice = false;

    // Enable wakelock to prevent screen sleep and sensor throttling mid-drive
    try {
      await WakelockPlus.enable();
    } catch (_) {}

    // Start on-device drive session CSV logging
    await _logger.startLogging();
    _rawGnssSubscription?.cancel();
    _rawGnssSubscription = _liveSensorAdapter.rawGnssStream.listen((gnss) {
      _logger.recordRawGnss(gnss);
    });

    setState(() {
      _isDemoMode = false;
      _state = _state.copyWith(isNavigating: true);
      _traveledPoints = [startPoint];
      _remainingPoints = _state.route!.points;
    });

    _idrEngine.setRoute(_state.route!.points);
    await _idrEngine.start(
      _liveSensorAdapter,
      startLat: startPoint.latitude,
      startLon: startPoint.longitude,
      startHeading: _vehicleHeading,
    );
  }

  /// Stops dead reckoning navigation
  Future<void> _stopNavigation() async {
    // Disable wakelock
    try {
      await WakelockPlus.disable();
    } catch (_) {}

    _rawGnssSubscription?.cancel();
    _rawGnssSubscription = null;
    final logPath = await _logger.stopLogging();

    await _idrEngine.stop();
    _telemetryNotifier.value = null;
    setState(() {
      _state = _state.copyWith(isNavigating: false);
      _traveledPoints = [];
      _remainingPoints = [];
    });
    // Reset camera to north up
    _mapController.rotate(0);

    if (logPath != null && mounted) {
      final fileName = logPath.replaceAll(r'\', '/').split('/').last;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Drive session saved: $fileName',
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'SHARE / PLOT',
            textColor: const Color(0xFF38BDF8),
            onPressed: () => _logger.shareCurrentLog(),
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  /// Toggles manual GNSS blackout for controlled filming of dead-reckoning transitions
  void _toggleForceBlackout() {
    final isBlocked = _idrEngine.toggleGnssForceBlocked();
    HapticFeedback.heavyImpact();
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isBlocked ? const Color(0xFFDC2626) : const Color(0xFF10B981),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        content: Row(
          children: [
            Icon(
              isBlocked
                  ? Icons.signal_cellular_connected_no_internet_4_bar_rounded
                  : Icons.satellite_alt_rounded,
              color: Colors.white,
              size: 22,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isBlocked
                    ? 'SIMULATED GNSS OUTAGE ACTIVATED\nRunning Dead-Reckoning (ESKF + VelocityCNN + NHC)'
                    : 'GNSS RESTORED\nSatellites reacquired • ESKF Kalman correction active',
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, height: 1.3),
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Launch Demo Mode using recorded dataset replay
  Future<void> _startDemoMode() async {
    setState(() => _message = 'Loading Demo Mode test dataset…');
    try {
      // Enable wakelock for demo mode
      try {
        await WakelockPlus.enable();
      } catch (_) {}

      await _replayAdapter.loadDataset();

      // Use actual dataset ground-truth coordinates from IO-VNBD test_dataset.csv
      // Start: (24.3767, 88.5490), End: (24.4613, 88.6133) — a real road corridor
      final startLat = 24.3767;
      final startLon = 88.5490;

      // Generate demo route from OSRM to ensure 100% road-snapped trajectory
      RouteData? demoRoute;
      try {
        demoRoute = await _routes.calculate(
          start: LatLng(startLat, startLon),
          end: const LatLng(24.4613, 88.6133),
        );
      } catch (_) {
        // Fallback: straight-line route along dataset trajectory
        demoRoute = RouteData(
          points: [
            LatLng(startLat, startLon),
            const LatLng(24.3760, 88.5470),
            const LatLng(24.3755, 88.5450),
            const LatLng(24.3750, 88.5440),
            const LatLng(24.3752, 88.5430),
            const LatLng(24.3850, 88.5500),
            const LatLng(24.4000, 88.5600),
            const LatLng(24.4200, 88.5700),
            const LatLng(24.4400, 88.5900),
            const LatLng(24.4613, 88.6133),
          ],
          distanceMeters: 14000,
          durationSeconds: 720,
          steps: const [
            NavigationStep(
              instruction: 'Proceed along Highway (Simulating GNSS Outage ahead)',
              distanceMeters: 14000,
              maneuver: 'straight',
            ),
          ],
        );
      }

      setState(() {
        _message = null;
        _isDemoMode = true;
        _state = _state.copyWith(
          isNavigating: true,
          userLocation: LatLng(startLat, startLon),
          destination: demoRoute!.points.last,
          route: demoRoute,
        );
        _traveledPoints = [LatLng(startLat, startLon)];
        _remainingPoints = demoRoute.points;
      });

      _mapController.move(LatLng(startLat, startLon), 16.0);
      _idrEngine.setRoute(demoRoute.points);
      CachedTileProvider.precacheRoute(demoRoute.points);

      await _idrEngine.start(
        _replayAdapter,
        startLat: startLat,
        startLon: startLon,
        startHeading: -98.4, // Match dataset initial heading
      );
    } catch (e) {
      setState(() => _message = 'Error starting Demo Mode: $e');
    }
  }

  Future<void> _stopDemoMode() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}

    await _idrEngine.stop();
    _telemetryNotifier.value = null;
    setState(() {
      _isDemoMode = false;
      _state = _state.copyWith(isNavigating: false);
      _traveledPoints = [];
      _remainingPoints = [];
    });
    _mapController.rotate(0);
    _startLiveLocation();
  }

  void _toggleHeadingUp() {
    setState(() => _isHeadingUp = !_isHeadingUp);
    if (!_isHeadingUp) {
      _mapController.rotate(0);
    }
  }

  void _recenterCamera() {
    setState(() => _isUserDragging = false);
    if (_state.userLocation != null) {
      if (_isHeadingUp && (_state.isNavigating || _isDemoMode)) {
        _mapController.moveAndRotate(
          _state.userLocation!,
          17.0,
          -_vehicleHeading,
        );
      } else {
        _mapController.move(_state.userLocation!, 16);
      }
    }
  }

  @override
  void dispose() {
    try {
      WakelockPlus.disable();
    } catch (_) {}
    _markerAnim.dispose();
    _telemetryNotifier.dispose();
    _rawGnssSubscription?.cancel();
    _logger.stopLogging();
    _locationSubscription?.cancel();
    _telemetrySubscription?.cancel();
    _idrEngine.dispose();
    _liveSensorAdapter.dispose();
    _replayAdapter.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final center = _state.userLocation ?? const LatLng(12.9716, 77.6101);
    final isTest = const bool.fromEnvironment('FLUTTER_TEST');
    final isNavigating = _state.isNavigating || _isDemoMode;

    return Scaffold(
      body: Stack(
        children: [
          // 1. OpenStreetMap Map View
          GestureDetector(
            onPanStart: (_) {
              if (isNavigating) setState(() => _isUserDragging = true);
            },
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 15.5,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              ),
              children: [
                if (!isTest)
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.navigate.phase1',
                    tileProvider: CachedTileProvider(),
                  ),

                // Traveled route polyline (gray, dimmed)
                if (_traveledPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _traveledPoints,
                        color: const Color(0xFF9CA3AF),
                        strokeWidth: 5,
                      ),
                    ],
                  ),

                // Remaining route polyline (vibrant blue with white border)
                if (_remainingPoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _remainingPoints,
                        color: const Color(0xFF1A73E8),
                        strokeWidth: 7,
                        borderStrokeWidth: 2,
                        borderColor: Colors.white,
                      ),
                    ],
                  ),

                // Static route preview polyline (shown before navigation starts)
                if (_state.route != null && !isNavigating)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _state.route!.points,
                        color: const Color(0xFF1A73E8),
                        strokeWidth: 7,
                        borderStrokeWidth: 2,
                        borderColor: Colors.white,
                      ),
                    ],
                  ),

                // Dynamic Spatial Uncertainty Circle (Tier 3.3 Confidence-Transparent UI)
                // Grows during dead reckoning and contracts down upon GNSS reacquisition
                if (_state.userLocation != null)
                  ValueListenableBuilder<NavigationTelemetry?>(
                    valueListenable: _telemetryNotifier,
                    builder: (context, telem, _) {
                      final double uncertaintyM = (telem?.positionUncertainty ?? 4.0).clamp(3.0, 60.0);
                      final bool isDr = telem?.navMode == NavMode.deadReckoning;
                      final Color circleColor = isDr ? const Color(0xFFF59E0B) : const Color(0xFF10B981);
                      return CircleLayer(
                        circles: [
                          CircleMarker(
                            point: LatLng(
                              _renderLat ?? _state.userLocation!.latitude,
                              _renderLng ?? _state.userLocation!.longitude,
                            ),
                            radius: uncertaintyM,
                            useRadiusInMeter: true,
                            color: circleColor.withValues(alpha: 0.16),
                            borderColor: circleColor.withValues(alpha: 0.70),
                            borderStrokeWidth: 1.5,
                          ),
                        ],
                      );
                    },
                  ),

                MarkerLayer(
                  markers: [
                    if (_state.userLocation != null)
                      Marker(
                        point: LatLng(
                          _renderLat ?? _state.userLocation!.latitude,
                          _renderLng ?? _state.userLocation!.longitude,
                        ),
                        width: 60,
                        height: 60,
                        child: RepaintBoundary(
                          child: AnimatedBuilder(
                            animation: _markerAnim,
                            builder: (context, _) => _directionalVehicleMarker(),
                          ),
                        ),
                      ),
                    if (_state.destination != null)
                      Marker(
                        point: _state.destination!,
                        width: 52,
                        height: 62,
                        child: _destinationMarker(),
                      ),
                  ],
                ),
              ],
            ),
          ),

          // 2. Top Green Turn-by-Turn Maneuver Card (active navigation only)
          if (isNavigating && _state.route != null && _state.route!.steps.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _buildManeuverCard(),
            ),

          // 3. Top Search & Demo Toggle (when NOT actively navigating)
          if (!isNavigating)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: LocationPicker(
                            sourceLabel: _state.userLocation == null ? 'Waiting for GPS…' : 'Your location',
                            currentLocation: _state.userLocation,
                            onDestinationSelected: _selectDestination,
                            onRetryLocation: _startLiveLocation,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _demoModeBadgeButton(),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_message != null) _messageCard(),
                  ],
                ),
              ),
            ),

          // 4. Telemetry HUD (active during navigation or demo, scoped high-frequency rebuild)
          if (isNavigating)
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).padding.top +
                  (_state.route != null && _state.route!.steps.isNotEmpty ? 135 : 8),
              child: AnimatedOpacity(
                opacity: _isHudVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: IgnorePointer(
                  ignoring: !_isHudVisible,
                  child: ValueListenableBuilder<NavigationTelemetry?>(
                    valueListenable: _telemetryNotifier,
                    builder: (context, telem, _) {
                      if (telem == null) return const SizedBox.shrink();
                      return TelemetryHud(
                        telemetry: telem,
                        onToggleForceBlackout: !_isDemoMode ? _toggleForceBlackout : null,
                        onShareLog: _logger.isLogging ? () => _logger.shareCurrentLog() : null,
                        isLogging: _logger.isLogging,
                      );
                    },
                  ),
                ),
              ),
            ),


          // 5. Map Action Controls (Compass, Recenter, My Location, Blackout Toggle)
          Positioned(
            right: 18,
            bottom: isNavigating
                ? (_isDemoMode ? 200 : 190)
                : (_state.route != null ? 280 : 28),
            child: Column(
              children: [
                if (isNavigating && !_isDemoMode) ...[
                  ValueListenableBuilder<NavigationTelemetry?>(
                    valueListenable: _telemetryNotifier,
                    builder: (context, telem, _) {
                      final isBlocked = telem?.isGnssForceBlocked ?? false;
                      return _roundControl(
                        isBlocked
                            ? Icons.signal_cellular_connected_no_internet_4_bar_rounded
                            : Icons.satellite_alt_rounded,
                        _toggleForceBlackout,
                        tooltip: isBlocked ? 'Restore GNSS' : 'Simulate Blackout',
                        color: isBlocked ? const Color(0xFFEF4444) : const Color(0xFF34D399),
                      );
                    },
                  ),
                  const SizedBox(height: 10),
                  _roundControl(
                    _isHudVisible ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                    () => setState(() => _isHudVisible = !_isHudVisible),
                    tooltip: _isHudVisible ? 'Hide Telemetry' : 'Show Telemetry',
                    color: _isHudVisible ? const Color(0xFF38BDF8) : const Color(0xFF94A3B8),
                  ),
                  const SizedBox(height: 10),
                  _roundControl(
                    Icons.tune_rounded,
                    () => StealthSettingsDialog.show(context),
                    tooltip: 'Dead Reckoning Calibration',
                    color: const Color(0xFF38BDF8),
                  ),
                  const SizedBox(height: 10),
                ],
                if (isNavigating) ...[
                  _roundControl(
                    _isHeadingUp ? Icons.explore_rounded : Icons.explore_off_rounded,
                    _toggleHeadingUp,
                    tooltip: _isHeadingUp ? 'North Up' : 'Heading Up',
                  ),
                  const SizedBox(height: 10),
                ],
                if (_isUserDragging && isNavigating)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _roundControl(
                      Icons.gps_fixed_rounded,
                      _recenterCamera,
                      tooltip: 'Recenter',
                      color: const Color(0xFF1A73E8),
                    ),
                  ),
                if (isNavigating) ...[
                  _roundControl(
                    _getVehicleIcon(_idrEngine.vehicleProfile.type),
                    _cycleVehicleProfile,
                    tooltip: 'Vehicle: ${_idrEngine.vehicleProfile.name}',
                    color: const Color(0xFF6366F1),
                  ),
                  const SizedBox(height: 10),
                  _roundControl(
                    _idrEngine.isEmergencyMode
                        ? Icons.local_hospital_rounded
                        : Icons.local_hospital_outlined,
                    _toggleEmergencyMode,
                    tooltip: 'Emergency Responder Mode',
                    color: _idrEngine.isEmergencyMode
                        ? const Color(0xFFEF4444)
                        : Colors.white70,
                  ),
                  const SizedBox(height: 10),
                ],
                _roundControl(Icons.my_location_rounded, () {
                  if (_state.userLocation != null) {
                    _mapController.move(_state.userLocation!, 16);
                    setState(() => _isUserDragging = false);
                  } else {
                    _startLiveLocation();
                  }
                }),
              ],
            ),
          ),

          // 6. Bottom Navigation Trip Bar (during live navigation)
          if (isNavigating && !_isDemoMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildBottomTripBar(),
            ),

          // 7. Navigation Panel — Route Preview (before navigation starts)
          if (_state.route != null && !isNavigating)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: NavigationPanel(
                route: _state.route,
                isNavigating: _state.isNavigating,
                onStart: _startLiveNavigation,
                onStop: _stopNavigation,
              ),
            ),

          // 8. Demo Control Panel (during demo mode)
          if (_isDemoMode)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: DemoControlPanel(
                replayAdapter: _replayAdapter,
                isNavigating: _state.isNavigating,
                onStart: _startDemoMode,
                onPause: () => _idrEngine.pause(),
                onResume: () => _idrEngine.resume(),
                onRestart: () => _replayAdapter.restart(),
                onStop: _stopDemoMode,
                onSpeedChanged: (s) => _replayAdapter.setSpeed(s),
              ),
            ),

          // 8b. Proactive Differentiator Alert Banners (Denial Lookahead, Spoofing, Hard Braking, Wrong-Way)
          if (isNavigating)
            Positioned(
              left: 16,
              right: 16,
              bottom: _isDemoMode ? 190 : 170,
              child: ValueListenableBuilder<NavigationTelemetry?>(
                valueListenable: _telemetryNotifier,
                builder: (context, telem, _) {
                  if (telem == null) return const SizedBox.shrink();
                  return _buildAlertBanners(telem);
                },
              ),
            ),

          // 10. Calibration & Alignment Onboarding Overlay (Top z-index, right: 76 avoids collision with right-side map action controls)
          if (isNavigating && !_isDemoMode && !_dismissedCalibrationNotice)
            Positioned(
              left: 16,
              right: 76,
              top: MediaQuery.of(context).padding.top +
                  (_state.route != null && _state.route!.steps.isNotEmpty ? 220 : 96),
              child: ValueListenableBuilder<NavigationTelemetry?>(
                valueListenable: _telemetryNotifier,
                builder: (context, telem, _) {
                  if (telem == null) return const SizedBox.shrink();
                  return _buildCalibrationOverlay(telem);
                },
              ),
            ),
        ],
      ),
    );
  }

  // ─── Google Maps-Style Top Green Maneuver Card ───────────────────────

  Widget _buildManeuverCard() {
    final step = _state.currentStep;
    if (step == null) return const SizedBox.shrink();

    final distMeters = _state.distanceToNextStepMeters;
    final distText = distMeters >= 1000
        ? '${(distMeters / 1000).toStringAsFixed(1)} km'
        : '${distMeters.toInt()} m';

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.88),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
            border: Border(
              bottom: BorderSide(
                color: Colors.white.withValues(alpha: 0.15),
                width: 0.8,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 16, 16),
              child: Row(
                children: [
                  // Maneuver Icon Badge (iOS emerald green gradient pill)
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF10B981), Color(0xFF059669)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF10B981).withValues(alpha: 0.40),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Icon(
                      _getManeuverIcon(step.maneuver, step.modifier),
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Distance and instruction
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'In $distText',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          step.instruction,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // iOS close button
                  IosIconButton(
                    icon: Icons.close_rounded,
                    onPressed: _isDemoMode ? _stopDemoMode : _stopNavigation,
                    size: 38,
                    iconSize: 18,
                    backgroundColor: Colors.white.withValues(alpha: 0.12),
                    foregroundColor: Colors.white,
                    tooltip: 'Exit navigation',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  IconData _getManeuverIcon(String maneuver, String? modifier) {
    if (maneuver == 'turn') {
      if (modifier == 'left' || modifier == 'slight left' || modifier == 'sharp left') {
        return Icons.turn_left_rounded;
      }
      if (modifier == 'right' || modifier == 'slight right' || modifier == 'sharp right') {
        return Icons.turn_right_rounded;
      }
      if (modifier == 'uturn') return Icons.u_turn_left_rounded;
    }
    if (maneuver == 'roundabout') return Icons.roundabout_left_rounded;
    if (maneuver == 'fork') return Icons.fork_right_rounded;
    if (maneuver == 'merge') return Icons.merge_rounded;
    if (maneuver == 'arrive') return Icons.flag_rounded;
    if (maneuver == 'depart') return Icons.navigation_rounded;
    return Icons.straight_rounded;
  }

  // ─── Bottom Trip Status Bar (Dark Frosted Glass + High-Freq Tier) ────

  Widget _buildBottomTripBar() {
    final remainDist = _state.remainingDistanceMeters;
    final route = _state.route;

    return ValueListenableBuilder<NavigationTelemetry?>(
      valueListenable: _telemetryNotifier,
      builder: (context, telemetry, _) {
        final speed = telemetry?.speedKmh ?? 0.0;
        final navMode = telemetry?.navMode ?? NavMode.gnssIns;

        double remainMin = 0;
        if (route != null && speed > 2.0) {
          remainMin = (remainDist / (speed / 3.6)) / 60.0;
        } else if (route != null) {
          remainMin = route.durationSeconds / 60.0;
        }

        final now = DateTime.now();
        final eta = now.add(Duration(minutes: remainMin.round()));
        final etaStr = '${eta.hour}:${eta.minute.toString().padLeft(2, '0')}';

        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.90),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 0.8,
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 28,
                    offset: const Offset(0, -6),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        _tripMetric(etaStr, 'ETA'),
                        _tripMetric('${remainMin.toInt()} min', 'REMAIN'),
                        _tripMetric(
                          remainDist >= 1000
                              ? '${(remainDist / 1000).toStringAsFixed(1)} km'
                              : '${remainDist.toInt()} m',
                          'DISTANCE',
                        ),
                        _tripMetric('${speed.toInt()}', 'km/h'),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        // IDR status glass pill
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: navMode == NavMode.deadReckoning
                                ? const Color(0xFFF59E0B).withValues(alpha: 0.18)
                                : const Color(0xFF10B981).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: navMode == NavMode.deadReckoning
                                  ? const Color(0xFFF59E0B).withValues(alpha: 0.40)
                                  : const Color(0xFF10B981).withValues(alpha: 0.40),
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                navMode == NavMode.deadReckoning
                                    ? Icons.explore_rounded
                                    : Icons.satellite_alt_rounded,
                                size: 14,
                                color: navMode == NavMode.deadReckoning
                                    ? const Color(0xFFFBBF24)
                                    : const Color(0xFF34D399),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                navMode == NavMode.deadReckoning
                                    ? 'DEAD RECKONING'
                                    : 'GNSS FIX (10Hz)',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  color: navMode == NavMode.deadReckoning
                                      ? const Color(0xFFFBBF24)
                                      : const Color(0xFF34D399),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        // Exit Button
                        IosGlassButton(
                          onPressed: _stopNavigation,
                          icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                          label: 'EXIT',
                          isDestructive: true,
                          height: 38,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          borderRadius: 12,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _tripMetric(String value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 9,
              letterSpacing: .8,
              color: Color(0xFF94A3B8),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }


  // ─── Demo Mode Toggle ──────────────────────────────────────────────

  Widget _demoModeBadgeButton() {
    return Container(
      decoration: BoxDecoration(
        color: _isDemoMode
            ? const Color(0xFF10B981).withValues(alpha: 0.85)
            : const Color(0xFF0F172A).withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: IosIconButton(
        icon: Icons.science_rounded,
        onPressed: () {
          if (_isDemoMode) {
            _stopDemoMode();
          } else {
            _showDemoConfirmationSheet();
          }
        },
        size: 48,
        iconSize: 22,
        foregroundColor: _isDemoMode ? Colors.white : const Color(0xFF38BDF8),
        tooltip: 'Demo Mode (Simulate GNSS Outage)',
      ),
    );
  }

  void _showDemoConfirmationSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withValues(alpha: 0.94),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.18),
                    width: 0.8,
                  ),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.40),
                    blurRadius: 32,
                    offset: const Offset(0, -8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // iOS sheet drag handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 18),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.18),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.science_rounded, color: Color(0xFF38BDF8), size: 22),
                      ),
                      const SizedBox(width: 12),
                      const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'IDR DEMO MODE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          Text(
                            'Hardware-in-the-loop GNSS Blackout Simulation',
                            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Demonstrates full Intelligent Dead Reckoning using vehicular IMU telemetry with a 45-second total GNSS blackout.\n\nFuses on-device VelocityCNN, 15-state ESKF, Non-Holonomic Constraints (NHC), and offline road-network map matching.',
                    style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13.5, height: 1.45),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.10), width: 0.8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.layers_outlined, color: Color(0xFF38BDF8), size: 18),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Dataset: IO-VNBD (100 Hz IMU, 120s sequence)',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: IosGlassButton(
                      onPressed: () {
                        Navigator.pop(context);
                        _startDemoMode();
                      },
                      icon: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 22),
                      label: 'START DEMO NAVIGATION',
                      backgroundColor: const Color(0xFF10B981),
                      height: 52,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ─── Markers & Overlays ─────────────────────────────────────────────

  Widget _directionalVehicleMarker() {
    final telem = _telemetryNotifier.value;
    final isDr = telem?.navMode == NavMode.deadReckoning;

    // Visual screen angle:
    // In Heading-Up navigation mode, the camera rotates with the car so the road ahead
    // is always straight UP on the phone screen (0°).
    // In North-Up mode, the arrow rotates by compass heading relative to North.
    final double screenAngleDeg = _isHeadingUp
        ? 0.0
        : (((_renderHeading ?? _vehicleHeading) + _mapController.camera.rotation) % 360);

    return GoogleMapsPuck(
      screenAngleDeg: screenAngleDeg,
      isNavigating: _state.isNavigating || _isDemoMode,
      isDrMode: isDr,
      size: 44.0,
    );
  }

  /// Interactive onboarding card guiding user through stationary gravity & yaw alignment
  Widget _buildCalibrationOverlay(NavigationTelemetry telem) {
    if (telem.isFullyCalibrated) {
      // Auto-dismiss 3.5 seconds after full alignment convergence
      Future.delayed(const Duration(milliseconds: 3500), () {
        if (mounted && !_dismissedCalibrationNotice) {
          setState(() => _dismissedCalibrationNotice = true);
        }
      });
    }

    final bool isGravityDone = telem.isGravityCalibrated;
    final bool isFullyDone = telem.isFullyCalibrated;

    final Color accentColor = isFullyDone
        ? const Color(0xFF10B981)
        : (isGravityDone ? const Color(0xFF38BDF8) : const Color(0xFFF59E0B));

    final String phaseBadge = isFullyDone
        ? 'SYSTEM LOCKED'
        : (isGravityDone ? 'PHASE 2 / 2 • YAW ALIGNMENT' : 'PHASE 1 / 2 • CALIBRATION');

    final String title = isFullyDone
        ? 'Dead Reckoning Ready'
        : (isGravityDone ? 'Drive Forward Straight' : 'Hold Vehicle Still');

    final String subtitle = isFullyDone
        ? 'Vehicle orientation aligned • ESKF 100 Hz fusion active'
        : (isGravityDone
            ? 'Drive > 6 km/h to lock vehicle yaw (${telem.calibrationProgressPercent}%)'
            : 'Hold vehicle still for 0.5s to sample gravity (${telem.calibrationProgressPercent}%)');

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: accentColor.withValues(alpha: 0.50), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: accentColor.withValues(alpha: 0.20),
                blurRadius: 20,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      phaseBadge,
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () {
                        HapticFeedback.lightImpact();
                        setState(() => _dismissedCalibrationNotice = true);
                      },
                      child: Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    isFullyDone
                        ? Icons.check_circle_rounded
                        : (isGravityDone ? Icons.navigation_rounded : Icons.sensors_rounded),
                    color: accentColor,
                    size: 24,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 11.5,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!isFullyDone) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: (telem.calibrationProgressPercent / 100.0).clamp(0.05, 1.0),
                          minHeight: 5,
                          backgroundColor: Colors.white.withValues(alpha: 0.12),
                          valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        setState(() => _dismissedCalibrationNotice = true);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'Dismiss',
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageCard() => ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A).withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 0.8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                const Icon(CupertinoIcons.info_circle_fill, color: Color(0xFF38BDF8), size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _message!,
                    style: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w500),
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    setState(() => _message = null);
                  },
                  child: const Icon(CupertinoIcons.xmark_circle_fill, size: 20, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _roundControl(IconData icon, VoidCallback onTap, {String? tooltip, Color? color}) => GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.82),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 0.8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(icon, color: color ?? Colors.white, size: 20),
        ),
      );

  IconData _getVehicleIcon(VehicleType type) {
    switch (type) {
      case VehicleType.twoWheeler:
        return Icons.two_wheeler_rounded;
      case VehicleType.passengerCar:
        return Icons.directions_car_rounded;
      case VehicleType.commercialTruck:
        return Icons.local_shipping_rounded;
    }
  }

  void _cycleVehicleProfile() {
    HapticFeedback.selectionClick();
    final nextType = switch (_idrEngine.vehicleProfile.type) {
      VehicleType.passengerCar => VehicleType.twoWheeler,
      VehicleType.twoWheeler => VehicleType.commercialTruck,
      VehicleType.commercialTruck => VehicleType.passengerCar,
    };
    final newProfile = VehicleProfile.getProfile(nextType);
    _idrEngine.setVehicleProfile(newProfile);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Vehicle Profile: ${newProfile.name} (ZUPT: ${newProfile.zuptAccelVarianceThreshold} m/s², NHC: ${newProfile.nhcLateralNoiseStd})'),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF0F172A),
      ),
    );
  }

  void _toggleEmergencyMode() {
    HapticFeedback.heavyImpact();
    final nextState = !_idrEngine.isEmergencyMode;
    _idrEngine.setEmergencyMode(nextState);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nextState
            ? 'Emergency Responder Mode: Active (Dispatch broadcast ON)'
            : 'Emergency Responder Mode: Deactivated'),
        duration: const Duration(seconds: 2),
        backgroundColor: nextState ? const Color(0xFFDC2626) : const Color(0xFF0F172A),
      ),
    );
  }

  Widget _buildAlertBanners(NavigationTelemetry telem) {
    final List<Widget> banners = [];

    // 1. Denial zone lookahead / inside alert
    if (telem.denialZoneAlert != null) {
      final alert = telem.denialZoneAlert!;
      banners.add(_singleAlertPill(
        icon: alert.isInside ? Icons.shield_rounded : Icons.timer_outlined,
        title: alert.isInside ? 'INSIDE OUTAGE ZONE' : 'TUNNEL / BLACKOUT AHEAD',
        message: alert.bannerText,
        color: alert.isInside ? const Color(0xFFF59E0B) : const Color(0xFF6366F1),
      ));
    }

    // 2. Anti-spoofing alert
    if (telem.gnssIntegrity == GnssIntegrityStatus.suspectedSpoofing ||
        telem.gnssIntegrity == GnssIntegrityStatus.suspectedJamming) {
      banners.add(_singleAlertPill(
        icon: Icons.security_rounded,
        title: 'GNSS INTERFERENCE DETECTED',
        message: telem.gnssIntegrity == GnssIntegrityStatus.suspectedSpoofing
            ? 'Satellite claims speed while IMU is stationary — rejecting fix, trusting INS.'
            : 'Implausible position jump detected — rejecting corrupted signal.',
        color: const Color(0xFFEF4444),
      ));
    }

    // 3. Severe deceleration / collision spike
    if (telem.isSevereDeceleration) {
      banners.add(_singleAlertPill(
        icon: Icons.warning_rounded,
        title: 'HARD BRAKING SPIKE',
        message: 'Deceleration > 0.65g detected by IMU sensors.',
        color: const Color(0xFFFF3B30),
      ));
    }

    // 5. Emergency Responder dispatch broadcast
    if (telem.isEmergencyMode) {
      banners.add(_singleAlertPill(
        icon: Icons.local_hospital_rounded,
        title: 'EMERGENCY RESPONDER MODE',
        message: 'High-contrast HUD active · Live dispatch trajectory broadcast ON.',
        color: const Color(0xFF06B6D4),
      ));
    }

    if (banners.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: banners
          .map((b) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: b,
              ))
          .toList(),
    );
  }

  Widget _singleAlertPill({
    required IconData icon,
    required String title,
    required String message,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.55), width: 1.0),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.22),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
            children: [
              Icon(icon, color: color, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
  }

  Widget _destinationMarker() =>
      const Icon(Icons.location_on_rounded, color: Color(0xFFEF4444), size: 48);
}
