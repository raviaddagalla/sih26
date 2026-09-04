import 'dart:async';

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

class _MapScreenState extends State<MapScreen> {
  final _mapController = MapController();
  final _location = LocationService();
  final _routes = RouteService();

  // IDR Navigation Master Engine & Adapters
  final IdrEngine _idrEngine = IdrEngine();
  final AndroidSensorAdapter _liveSensorAdapter = AndroidSensorAdapter();
  final DatasetReplayAdapter _replayAdapter = DatasetReplayAdapter();

  StreamSubscription<LatLng>? _locationSubscription;
  StreamSubscription<NavigationTelemetry>? _telemetrySubscription;

  NavigationState _state = const NavigationState();
  NavigationTelemetry? _telemetry;
  String? _message;

  bool _isDemoMode = false;
  double _vehicleHeading = 0.0;

  @override
  void initState() {
    super.initState();

    // 1. Initialize the IDR Engine
    _idrEngine.initialize();

    // 2. Subscribe to 10 Hz IDR Engine Telemetry Output
    _telemetrySubscription = _idrEngine.telemetryStream.listen((telemetry) {
      if (!mounted) return;
      final newPos = LatLng(telemetry.latitude, telemetry.longitude);
      setState(() {
        _telemetry = telemetry;
        _vehicleHeading = telemetry.heading;
        _state = _state.copyWith(userLocation: newPos);
      });

      if (_state.isNavigating || _isDemoMode) {
        _mapController.move(newPos, _mapController.camera.zoom);
      }
    });

    // 3. Fallback Location subscription when not navigating with IDR
    _locationSubscription = _location.updates.listen((point) {
      if (!mounted || _idrEngine.isRunning) return;
      setState(() => _state = _state.copyWith(userLocation: point));
    });

    _startLiveLocation();
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
    });
  }

  /// Launch Demo Mode using recorded dataset replay
  Future<void> _startDemoMode() async {
    setState(() => _message = 'Loading Demo Mode test dataset…');
    try {
      await _replayAdapter.loadDataset();

      // Generate synthetic demo route along dataset trajectory
      final demoRoute = [
        const LatLng(24.3630, 88.6280),
        const LatLng(24.3645, 88.6310),
        const LatLng(24.3670, 88.6350),
        const LatLng(24.3710, 88.6400),
        const LatLng(24.3750, 88.6450),
        const LatLng(24.3800, 88.6520),
        const LatLng(24.3850, 88.6600),
      ];

      setState(() {
        _message = null;
        _isDemoMode = true;
        _state = _state.copyWith(
          isNavigating: true,
          userLocation: demoRoute.first,
          destination: demoRoute.last,
          route: RouteData(
            points: demoRoute,
            distanceMeters: 4800,
            durationSeconds: 360,
            steps: const [
              NavigationStep(
                instruction: 'Proceed along Highway 12 (Simulating GNSS Outage ahead)',
                distanceMeters: 4800,
                maneuver: 'straight',
              ),
            ],
          ),
        );
      });

      _mapController.move(demoRoute.first, 16.0);
      _idrEngine.setRoute(demoRoute);

      await _idrEngine.start(
        _replayAdapter,
        startLat: demoRoute.first.latitude,
        startLon: demoRoute.first.longitude,
        startHeading: 45.0,
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
    });
    _startLiveLocation();
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
    final center = _state.userLocation ?? const LatLng(24.3630, 88.6280);
    final isTest = const bool.fromEnvironment('FLUTTER_TEST');

    return Scaffold(
      body: Stack(
        children: [
          // 1. OpenStreetMap Map View
          FlutterMap(
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
              if (_state.route != null)
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

          // 2. Top Location Search & Demo Mode Toggle
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

          // 3. Telemetry HUD (active during navigation or demo)
          if (_telemetry != null)
            Positioned(
              left: 0,
              right: 0,
              top: MediaQuery.of(context).padding.top + 75,
              child: TelemetryHud(telemetry: _telemetry!),
            ),

          // 4. Map Action Controls (My Location & Recenter)
          Positioned(
            right: 18,
            bottom: _state.route == null ? 28 : (_isDemoMode ? 190 : 275),
            child: Column(
              children: [
                _roundControl(Icons.my_location_rounded, () {
                  if (_state.userLocation != null) {
                    _mapController.move(_state.userLocation!, 16);
                  } else {
                    _startLiveLocation();
                  }
                }),
              ],
            ),
          ),

          // 5. Navigation Panel (Turn-by-turn guidance and Start/Stop)
          if (_state.route != null && !_isDemoMode)
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

          // 6. Demo Control Panel (Play, Pause, Speed, Progress)
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
        ],
      ),
    );
  }

  /// Demo Mode Toggle Button at Top Right
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
              Row(
                children: [
                  const Icon(Icons.science_rounded, color: Color(0xFF38BDF8), size: 24),
                  const SizedBox(width: 10),
                  const Text(
                    'IDR DEMO MODE',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Demonstrates the complete Intelligent Dead Reckoning engine using recorded 100 Hz IMU data with simulated GNSS blackout segments (tunnel/urban canyon).\n\nRuns on-device VelocityCNN, 15-state ESKF, NHC, and map matching entirely offline.',
                style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  const Icon(Icons.description_outlined, color: Colors.white54, size: 18),
                  const SizedBox(width: 8),
                  const Text(
                    'Dataset: test_dataset.csv (100 Hz, 120s)',
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

  /// Directional Vehicle Marker rotated to the ESKF-estimated heading
  Widget _directionalVehicleMarker() {
    return Transform.rotate(
      angle: _vehicleHeading * (3.141592653589793 / 180.0),
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

  Widget _roundControl(IconData icon, VoidCallback onTap) => Material(
        color: Colors.white,
        elevation: 5,
        shadowColor: Colors.black26,
        shape: const CircleBorder(),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(icon, color: const Color(0xFF263238), size: 21),
          ),
        ),
      );

  Widget _destinationMarker() =>
      const Icon(Icons.location_on_rounded, color: Color(0xFFE55B4D), size: 48);
}
