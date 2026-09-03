import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../models/navigation_models.dart';
import 'ai_model_service.dart';
import 'fusion_engine.dart';
import 'sensor_service.dart';
import 'routing_service.dart';

class NavigationController {
  NavigationController({AiModelService? aiModel, GnssService? gnss, SensorService? sensors})
      : aiModel = aiModel ?? AiModelService(),
        gnss = gnss ?? GnssService(),
        sensors = sensors ?? SensorService();

  final AiModelService aiModel;
  final GnssService gnss;
  final SensorService sensors;
  final FusionEngine fusion = FusionEngine();
  final _controller = StreamController<NavigationSnapshot>.broadcast();
  final _demoTicker = StreamController<void>.broadcast();
  StreamSubscription<Position>? _gnssSubscription;
  StreamSubscription<List<SensorSample>>? _sensorSubscription;
  Timer? _demoTimer;
  
  List<LatLng>? _activeRoute;

  NavigationSnapshot _snapshot = NavigationSnapshot(
    mode: NavigationMode.gnss,
    speedKmh: 0,
    heading: 42,
    distanceKm: 0,
    signalLabel: 'CHECKING GNSS',
    accuracyMeters: 0,
    updatedAt: DateTime.now(),
    latitude: 12.9719,
    longitude: 77.5937,
    gpsAvailable: false,
    demoMode: true,
    activeRoute: null,
  );
  bool _isRunning = false;
  bool _demoMode = true;
  bool _demoGpsEnabled = true;
  final double _demoSpeedKmh = 34.2;
  double _demoHeading = 42;

  Stream<NavigationSnapshot> get snapshots => _controller.stream;
  NavigationSnapshot get current => _snapshot;
  bool get demoMode => _demoMode;
  bool get demoGpsEnabled => _demoGpsEnabled;

  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    if (const bool.fromEnvironment('FLUTTER_TEST')) {
      _emit(gpsAvailable: true, mode: NavigationMode.gnss, label: 'GPS ACTIVE', speedKmh: 34.2, accuracy: 3.4);
      return;
    }
    await aiModel.load();
    
    // In demo mode, we simulate the sensor stream using test dataset
    if (_demoMode) {
      _startDemoDatasetTicker();
    } else {
      sensors.start();
      _sensorSubscription = sensors.windows.listen((window) async {
        final speed = await aiModel.predictVelocityKmh(window);
        fusion.integrateVelocity(velocityKmh: speed, headingDeg: _snapshot.heading, dtSeconds: 0.1);
        _emit(speedKmh: speed, gpsAvailable: false, mode: NavigationMode.deadReckoning, label: 'GNSS OFF · AI ACTIVE');
      });
      await _startLiveGnss();
    }
  }

  Future<void> searchAndNavigate(String query) async {
    final start = LatLng(_snapshot.latitude, _snapshot.longitude);
    final destination = await RoutingService.searchDestination(query);
    if (destination != null) {
      final route = await RoutingService.fetchRoute(start, destination);
      if (route != null) {
        _activeRoute = route;
        fusion.activeRoute = route;
        _emit(gpsAvailable: _snapshot.gpsAvailable, mode: _snapshot.mode, label: _snapshot.signalLabel);
      }
    }
  }

  // Demo Dataset Player
  List<dynamic> _demoData = [];
  int _demoCursor = 0;

  Future<void> _startDemoDatasetTicker() async {
    try {
      final raw = await rootBundle.loadString('assets/demo_data.json');
      _demoData = jsonDecode(raw) as List<dynamic>;
    } catch (e) {
      print("Failed to load demo data: $e");
    }
    
    _demoTimer?.cancel();
    _demoTimer = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      if (_demoData.isEmpty) return;
      
      // Build a 200-sample window from the cursor
      if (_demoCursor + 200 > _demoData.length) {
        _demoCursor = 0; // Loop
      }
      
      List<SensorSample> window = [];
      for (int i = 0; i < 200; i++) {
        final row = _demoData[_demoCursor + i];
        window.add(SensorSample(
          ax: (row['ax'] as num).toDouble(),
          ay: (row['ay'] as num).toDouble(),
          az: (row['az'] as num).toDouble(),
          gx: (row['gx'] as num).toDouble(),
          gy: (row['gy'] as num).toDouble(),
          gz: (row['gz'] as num).toDouble(),
          timestamp: DateTime.now(),
        ));
      }
      
      // Advance cursor by 10 samples (simulating 100ms stride at 100Hz)
      _demoCursor += 10;
      
      final currentGps = _demoData[_demoCursor + 199];
      final double? lat = currentGps['lat'] != null ? (currentGps['lat'] as num).toDouble() : null;
      final double? lon = currentGps['lon'] != null ? (currentGps['lon'] as num).toDouble() : null;

      if (_demoGpsEnabled && lat != null && lon != null) {
        fusion.seedFromGnss(Position(latitude: lat, longitude: lon, timestamp: DateTime.now(), accuracy: 3, altitude: 0, altitudeAccuracy: 1, heading: _demoHeading, headingAccuracy: 3, speed: 0, speedAccuracy: 1));
        _emit(speedKmh: _snapshot.speedKmh, gpsAvailable: true, mode: NavigationMode.gnss, label: 'DEMO GPS ACTIVE');
      } else {
        final speed = await aiModel.predictVelocityKmh(window);
        fusion.integrateVelocity(velocityKmh: speed, headingDeg: _snapshot.heading, dtSeconds: 0.1);
        _emit(speedKmh: speed, gpsAvailable: false, mode: NavigationMode.deadReckoning, label: 'DEMO GPS OFF · AI ACTIVE');
      }
    });
  }

  Future<void> _startLiveGnss() async {
    if (!await gnss.ensurePermission()) {
      _emit(gpsAvailable: false, mode: NavigationMode.deadReckoning, label: 'GNSS UNAVAILABLE');
      return;
    }
    _gnssSubscription = gnss.positions.listen((position) {
      fusion.seedFromGnss(position);
      final weak = position.accuracy > 25;
      _emit(
        speedKmh: position.speed.isFinite && position.speed >= 0 ? position.speed * 3.6 : _snapshot.speedKmh,
        gpsAvailable: !weak,
        mode: weak ? NavigationMode.deadReckoning : NavigationMode.gnss,
        label: weak ? 'WEAK GNSS · FUSION ACTIVE' : 'GNSS LOCKED',
        accuracy: position.accuracy,
      );
    });
  }

  void setDemoMode(bool value) {
    _demoMode = value;
    if (!value) {
      _demoGpsEnabled = true;
      _demoTimer?.cancel();
      _startLiveGnss();
    } else {
      _startDemoTicker();
    }
    _emit(label: value ? 'DEMO GPS ACTIVE' : 'CHECKING GNSS', gpsAvailable: value && _demoGpsEnabled, mode: value && _demoGpsEnabled ? NavigationMode.gnss : NavigationMode.deadReckoning);
  }

  void toggleOutage() => toggleDemoGps();

  void toggleDemoGps() {
    if (!_demoMode) return;
    _demoGpsEnabled = !_demoGpsEnabled;
    _emit(
      speedKmh: _demoGpsEnabled ? _demoSpeedKmh : _demoSpeedKmh - 0.4,
      gpsAvailable: _demoGpsEnabled,
      mode: _demoGpsEnabled ? NavigationMode.gnss : NavigationMode.deadReckoning,
      label: _demoGpsEnabled ? 'DEMO GPS ACTIVE' : 'DEMO GPS OFF · AI ACTIVE',
    );
  }

  void _startDemoTicker() {
    _demoTimer?.cancel();
    if (!_demoMode) return;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _demoHeading = (_demoHeading + 0.4) % 360;
      if (!_demoGpsEnabled) {
        fusion._demoStep(_demoSpeedKmh, _demoHeading);
      }
      _emit(speedKmh: _demoSpeedKmh, gpsAvailable: _demoGpsEnabled, mode: _demoGpsEnabled ? NavigationMode.gnss : NavigationMode.deadReckoning, label: _demoGpsEnabled ? 'DEMO GPS ACTIVE' : 'DEMO GPS OFF · AI ACTIVE');
    });
  }

  void _emit({double? speedKmh, required bool gpsAvailable, required NavigationMode mode, required String label, double? accuracy}) {
    final point = fusion.position;
    _snapshot = NavigationSnapshot(
      mode: mode,
      speedKmh: speedKmh ?? _snapshot.speedKmh,
      heading: _demoMode ? _demoHeading : fusion.headingDeg,
      distanceKm: fusion.distanceKm,
      signalLabel: label,
      accuracyMeters: accuracy ?? (gpsAvailable ? 3.4 : 0),
      updatedAt: DateTime.now(),
      latitude: point?.latitude ?? _snapshot.latitude,
      longitude: point?.longitude ?? _snapshot.longitude,
      gpsAvailable: gpsAvailable,
      demoMode: _demoMode,
      activeRoute: _activeRoute,
    );
    _controller.add(_snapshot);
  }

  void dispose() {
    _demoTimer?.cancel();
    _gnssSubscription?.cancel();
    _sensorSubscription?.cancel();
    sensors.dispose();
    aiModel.close();
    _controller.close();
    _demoTicker.close();
  }
}

extension on FusionEngine {
  void _demoStep(double speedKmh, double headingDeg) {
    if (position == null) seedFromGnss(Position(latitude: 12.9719, longitude: 77.5937, timestamp: DateTime.now(), accuracy: 3, altitude: 900, altitudeAccuracy: 1, heading: headingDeg, headingAccuracy: 3, speed: speedKmh / 3.6, speedAccuracy: 1));
    integrateVelocity(velocityKmh: speedKmh, headingDeg: headingDeg, dtSeconds: 0.5);
  }
}
