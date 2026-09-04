import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:location/location.dart' as loc;
import 'sensor_data_source.dart';
import '../idr_engine/core/imu_sample.dart';
import '../idr_engine/core/gnss_sample.dart';

/// Live sensor adapter connecting Android hardware (Sensors & GNSS)
/// to the standardized SensorDataSource interface.
class AndroidSensorAdapter implements SensorDataSource {
  final _imuController = StreamController<ImuSample>.broadcast();
  final _gnssController = StreamController<GnssSample>.broadcast();

  @override
  Stream<ImuSample> get imuStream => _imuController.stream;

  @override
  Stream<GnssSample> get gnssStream => _gnssController.stream;

  bool _isRunning = false;
  bool _isPaused = false;

  @override
  bool get isRunning => _isRunning;

  @override
  bool get isPaused => _isPaused;

  @override
  String get sourceName => 'Android Live Sensors (100Hz)';

  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<loc.LocationData>? _locSub;

  final loc.Location _location = loc.Location();

  // Cached latest readings for sync
  double _lastAx = 0.0, _lastAy = 0.0, _lastAz = 0.0;
  double _lastGx = 0.0, _lastGy = 0.0, _lastGz = 0.0;
  double? _lastMx, _lastMy, _lastMz;

  DateTime? _startEpoch;

  @override
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _isPaused = false;
    _startEpoch = DateTime.now();

    // 1. Configure Location Service for navigation
    await _setupLocation();

    // 2. Subscribe to high-rate IMU sensors (~100 Hz / SensorManager.SENSOR_DELAY_FASTEST)
    _accelSub = userAccelerometerEventStream(
      samplingPeriod: const Duration(microseconds: 10000), // 100 Hz target
    ).listen((event) {
      if (_isPaused) return;
      _lastAx = event.x;
      _lastAy = event.y;
      _lastAz = event.z;
      _emitImu();
    });

    _gyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(microseconds: 10000), // 100 Hz target
    ).listen((event) {
      if (_isPaused) return;
      _lastGx = event.x;
      _lastGy = event.y;
      _lastGz = event.z;
    });

    try {
      _magSub = magnetometerEventStream(
        samplingPeriod: const Duration(microseconds: 20000),
      ).listen((event) {
        if (_isPaused) return;
        _lastMx = event.x;
        _lastMy = event.y;
        _lastMz = event.z;
      });
    } catch (_) {
      // Magnetometer optional/not available on all devices
    }

    // 3. Subscribe to GNSS Location Stream
    _locSub = _location.onLocationChanged.listen((locData) {
      if (_isPaused) return;
      final t = _getRelativeTimeSeconds();
      final accuracy = locData.accuracy ?? 15.0;
      final speed = (locData.speed != null && locData.speed! >= 0) ? locData.speed! : 0.0;
      final heading = locData.heading ?? 0.0;
      final lat = locData.latitude ?? 0.0;
      final lon = locData.longitude ?? 0.0;

      // An update with valid coordinates and reasonable accuracy is marked available
      final isAvailable = (lat != 0.0 || lon != 0.0) && accuracy < 80.0;

      final sample = GnssSample(
        timestamp: t,
        latitude: lat,
        longitude: lon,
        altitude: locData.altitude,
        speed: speed,
        accuracy: accuracy,
        heading: heading,
        isAvailable: isAvailable,
      );
      _gnssController.add(sample);
    });
  }

  Future<void> _setupLocation() async {
    try {
      bool serviceEnabled = await _location.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _location.requestService();
      }

      loc.PermissionStatus permission = await _location.hasPermission();
      if (permission == loc.PermissionStatus.denied) {
        permission = await _location.requestPermission();
      }

      await _location.changeSettings(
        accuracy: loc.LocationAccuracy.high,
        interval: 500, // 2 Hz GNSS updates
        distanceFilter: 0.5, // meters
      );
    } catch (_) {}
  }

  double _getRelativeTimeSeconds() {
    if (_startEpoch == null) return 0.0;
    return DateTime.now().difference(_startEpoch!).inMicroseconds / 1e6;
  }

  void _emitImu() {
    final t = _getRelativeTimeSeconds();
    final sample = ImuSample(
      timestamp: t,
      ax: _lastAx,
      ay: _lastAy,
      az: _lastAz,
      gx: _lastGx,
      gy: _lastGy,
      gz: _lastGz,
      mx: _lastMx,
      my: _lastMy,
      mz: _lastMz,
    );
    _imuController.add(sample);
  }

  @override
  void pause() {
    _isPaused = true;
  }

  @override
  void resume() {
    _isPaused = false;
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _isPaused = false;
    await _accelSub?.cancel();
    await _gyroSub?.cancel();
    await _magSub?.cancel();
    await _locSub?.cancel();
    _accelSub = null;
    _gyroSub = null;
    _magSub = null;
    _locSub = null;
  }

  @override
  void dispose() {
    stop();
    _imuController.close();
    _gnssController.close();
  }
}
