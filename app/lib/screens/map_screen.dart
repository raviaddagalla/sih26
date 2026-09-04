import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/navigation_models.dart';
import '../services/location_service.dart';
import '../services/route_service.dart';
import '../widgets/navigation_panel.dart';
import '../services/geocoding_service.dart';
import '../widgets/location_picker.dart';
import '../widgets/telemetry_hud.dart';
import '../widgets/demo_control_panel.dart';
import '../idr_engine/idr_engine.dart';
import '../idr_engine/core/nav_telemetry.dart';
import '../adapters/android_sensor_adapter.dart';
import '../adapters/dataset_replay_adapter.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  final _mapController = MapController();
  final _location = LocationService();
  final _routes = RouteService();

  // IDR Navigation Master Engine & Adapters
  final IdrEngine _idrEngine = IdrEngine();
  late final AndroidSensorAdapter _liveSensorAdapter;
  final DatasetReplayAdapter _replayAdapter = DatasetReplayAdapter();

  StreamSubscription<LatLng>? _locationSubscription;
  StreamSubscription<NavigationTelemetry>? _telemetrySubscription;

  NavigationState _state = const NavigationState();
  NavigationTelemetry? _telemetry;
  String? _message;

  bool _isDemoMode = false;
  double _vehicleHeading = 0.0;
  bool _isHeadingUp = true;
  bool _isUserDragging = false;
  bool _isRerouting = false;

  // Sliced route points for polyline rendering
  List<LatLng> _traveledPoints = [];
  List<LatLng> _remainingPoints = [];

  @override
  void initState() {
    super.initState();

    // Share the unified LocationService with AndroidSensorAdapter
    _liveSensorAdapter = AndroidSensorAdapter(locationService: _location);

    // 1. Initialize the IDR Engine
    _idrEngine.initialize();

    // 2. Subscribe to 10 Hz IDR Engine Telemetry Output
    _telemetrySubscription = _idrEngine.telemetryStream.listen((telemetry) {
      if (!mounted) return;
      final newPos = LatLng(telemetry.latitude, telemetry.longitude);

      // Update route progress state
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

      setState(() {
        _telemetry = telemetry;
        _vehicleHeading = telemetry.heading;
        _state = _state.copyWith(
          userLocation: newPos,
          currentStepIndex: stepIdx,
          distanceToNextStepMeters: distNext,
          remainingDistanceMeters: telemetry.remainingDistanceMeters,
          isOffRoute: telemetry.isOffRoute,
        );

        // Update polyline slicing
        if (telemetry.slicedRoutePoints != null && _state.route != null) {
          _remainingPoints = (telemetry.slicedRoutePoints as List)
              .map((p) => p as LatLng)
              .toList();
          // Traveled = route start to current position
          final routePoints = _state.route!.points;
          final segIdx = telemetry.currentSegmentIndex;
          _traveledPoints = routePoints.sublist(0, min(segIdx + 1, routePoints.length));
          _traveledPoints.add(newPos);
        }
      });

      // Camera tracking during active navigation
      if ((_state.isNavigating || _isDemoMode) && !_isUserDragging) {
        if (_isHeadingUp) {
          _mapController.moveAndRotate(
            newPos,
            _mapController.camera.zoom.clamp(15.5, 18.0),
            -_vehicleHeading,
          );
        } else {
          _mapController.move(newPos, _mapController.camera.zoom);
        }
      }

      // Auto-reroute if off-route for extended time
      if (telemetry.isOffRoute && !_isRerouting && !_isDemoMode && _state.destination != null) {
        _autoReroute();
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
      setState(() {
        _state = _state.copyWith(route: route, isOffRoute: false);
        _traveledPoints = [];
        _remainingPoints = route.points;
      });
      _idrEngine.setRoute(route.points);
    } catch (_) {
      // Silently fail reroute
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
    await _idrEngine.stop();
    setState(() {
      _state = _state.copyWith(isNavigating: false);
      _telemetry = null;
      _traveledPoints = [];
      _remainingPoints = [];
    });
    // Reset camera to north up
    _mapController.rotate(0);
  }

  /// Launch Demo Mode using recorded dataset replay
  Future<void> _startDemoMode() async {
    setState(() => _message = 'Loading Demo Mode test dataset…');
    try {
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
    await _idrEngine.stop();
    setState(() {
      _isDemoMode = false;
      _state = _state.copyWith(isNavigating: false);
      _telemetry = null;
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

                MarkerLayer(
                  markers: [
                    if (_state.userLocation != null)
                      Marker(
                        point: _state.userLocation!,
                        width: 60,
                        height: 60,
                        child: _directionalVehicleMarker(),
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

          // 4. Telemetry HUD (active during navigation or demo)
          if (_telemetry != null && isNavigating)
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).padding.top + (_state.route != null && _state.route!.steps.isNotEmpty ? 135 : 8),
              child: TelemetryHud(telemetry: _telemetry!),
            ),

          // 5. Map Action Controls (Compass, Recenter, My Location)
          Positioned(
            right: 18,
            bottom: isNavigating
                ? (_isDemoMode ? 200 : 190)
                : (_state.route != null ? 280 : 28),
            child: Column(
              children: [
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

          // 9. Off-Route Warning Banner
          if (_state.isOffRoute && isNavigating && !_isDemoMode)
            Positioned(
              left: 16,
              right: 16,
              bottom: 170,
              child: _offRouteBanner(),
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

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1B8A4F), Color(0xFF10B981)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(20)),
        boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 12, offset: Offset(0, 4))],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Row(
            children: [
              // Maneuver Icon
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  _getManeuverIcon(step.maneuver, step.modifier),
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 16),
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
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      step.instruction,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.90),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              // Close navigation button
              IconButton(
                onPressed: _isDemoMode ? _stopDemoMode : _stopNavigation,
                icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 22),
              ),
            ],
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

  // ─── Bottom Trip Status Bar ───────────────────────────────────────────

  Widget _buildBottomTripBar() {
    final remainDist = _state.remainingDistanceMeters;
    final route = _state.route;
    final speed = _telemetry?.speedKmh ?? 0.0;

    // Estimate remaining time based on current speed
    double remainMin = 0;
    if (route != null && speed > 2.0) {
      remainMin = (remainDist / (speed / 3.6)) / 60.0;
    } else if (route != null) {
      remainMin = route.durationSeconds / 60.0;
    }

    // ETA
    final now = DateTime.now();
    final eta = now.add(Duration(minutes: remainMin.round()));
    final etaStr = '${eta.hour}:${eta.minute.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Color(0x26000000), blurRadius: 24, offset: Offset(0, -4))],
      ),
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
          const SizedBox(height: 12),
          Row(
            children: [
              // IDR status chip
              if (_telemetry != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _telemetry!.navMode == NavMode.deadReckoning
                        ? const Color(0xFFFEF3C7)
                        : const Color(0xFFD1FAE5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _telemetry!.navMode == NavMode.deadReckoning
                            ? Icons.explore_rounded
                            : Icons.satellite_alt_rounded,
                        size: 14,
                        color: _telemetry!.navMode == NavMode.deadReckoning
                            ? const Color(0xFFB45309)
                            : const Color(0xFF047857),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _telemetry!.navModeString,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: _telemetry!.navMode == NavMode.deadReckoning
                              ? const Color(0xFFB45309)
                              : const Color(0xFF047857),
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              // End Navigation button
              SizedBox(
                height: 42,
                child: FilledButton.icon(
                  onPressed: _stopNavigation,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: const Text('EXIT', style: TextStyle(fontWeight: FontWeight.w700)),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFEF4444),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tripMetric(String value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF172033)),
          ),
          const SizedBox(height: 2),
          Text(
            label.toUpperCase(),
            style: const TextStyle(fontSize: 9, letterSpacing: .8, color: Color(0xFF94A3B8), fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  // ─── Off-Route Warning Banner ──────────────────────────────────────

  Widget _offRouteBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF59E0B), width: 1.5),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      child: Row(
        children: [
          const Icon(Icons.wrong_location_rounded, color: Color(0xFFB45309), size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Off Route', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFB45309))),
                Text(
                  _isRerouting ? 'Rerouting…' : 'Recalculating route…',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                ),
              ],
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
        color: _isDemoMode ? const Color(0xFF10B981) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 2))],
      ),
      child: IconButton(
        onPressed: () {
          if (_isDemoMode) {
            _stopDemoMode();
          } else {
            _showDemoConfirmationSheet();
          }
        },
        icon: Icon(
          Icons.science_rounded,
          color: _isDemoMode ? Colors.white : const Color(0xFF1A73E8),
        ),
        tooltip: 'Demo Mode (Simulate GNSS Outage)',
      ),
    );
  }

  void _showDemoConfirmationSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.science_rounded, color: Color(0xFF38BDF8), size: 24),
                  SizedBox(width: 10),
                  Text(
                    'IDR DEMO MODE',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Demonstrates the complete Intelligent Dead Reckoning engine using recorded 10 Hz vehicular IMU data with a 45-second GNSS blackout.\n\nRuns on-device VelocityCNN, 15-state ESKF, NHC, and road-snapped map matching entirely offline.',
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 18),
              const Row(
                children: [
                  Icon(Icons.description_outlined, color: Colors.white54, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Dataset: IO-VNBD (100 Hz, 120s)',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontFamily: 'monospace'),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _startDemoMode();
                  },
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('START DEMO NAVIGATION'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ─── Markers ────────────────────────────────────────────────────────

  Widget _directionalVehicleMarker() {
    return Transform.rotate(
      angle: _vehicleHeading * (pi / 180.0),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0xFF1A73E8).withValues(alpha: 0.20),
              shape: BoxShape.circle,
            ),
          ),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _telemetry?.navMode == NavMode.deadReckoning
                  ? const Color(0xFFF59E0B)
                  : const Color(0xFF1A73E8),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
            ),
            child: const Icon(
              Icons.navigation_rounded,
              color: Colors.white,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageCard() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 14)],
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: Color(0xFFE55B4D)),
            const SizedBox(width: 10),
            Expanded(child: Text(_message!, style: const TextStyle(fontSize: 12))),
            IconButton(
              onPressed: () => setState(() => _message = null),
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
      );

  Widget _roundControl(IconData icon, VoidCallback onTap, {String? tooltip, Color? color}) => Material(
        color: Colors.white,
        elevation: 5,
        shadowColor: Colors.black26,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(icon, color: color ?? const Color(0xFF263238), size: 21),
          ),
        ),
      );

  Widget _destinationMarker() =>
      const Icon(Icons.location_on_rounded, color: Color(0xFFE55B4D), size: 48);
}
