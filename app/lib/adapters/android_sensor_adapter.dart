import 'dart:async';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:location/location.dart' as loc;
import 'sensor_data_source.dart';
import '../idr_engine/core/imu_sample.dart';
import '../idr_engine/core/gnss_sample.dart';

/// Live sensor adapter connecting Android hardware (Sensors & GNSS)
/// to the standardized SensorDataSource interface.
/// Features heavy vibration filtering specifically tuned for two-wheelers and scooters.
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
  String get sourceName => 'Android Live Sensors (100Hz Vibr-Filtered)';

  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<loc.LocationData>? _locSub;

  final loc.Location _location;
  final dynamic _locationService; // LocationService?

  // Cached latest readings with scooter engine vibration filter
  // Low-pass filter smoothing (alpha ~ 0.20 strongly attenuates 30-100Hz engine buzz)
  static const double _filterAlpha = 0.20;
  double _rawAx = 0.0, _rawAy = 0.0, _rawAz = 9.81;
  double _filtAx = 0.0, _filtAy = 0.0, _filtAz = 9.81;
  double _filtGx = 0.0, _filtGy = 0.0, _filtGz = 0.0;
  double? _lastMx, _lastMy, _lastMz;

  DateTime? _startEpoch;

  AndroidSensorAdapter({loc.Location? sharedLocation, dynamic locationService})
      : _location = sharedLocation ?? (locationService != null ? locationService.location as loc.Location : loc.Location()),
        _locationService = locationService;

  @override
  Future<void> start() async {
    if (_isRunning) return;
    _isRunning = true;
    _isPaused = false;
    _startEpoch = DateTime.now();

    // 1. Configure Location Service for high-accuracy vehicular tracking
    if (_locationService == null) {
      await _setupLocation();
    }

    // 2. Subscribe to raw Accelerometer (includes gravity for phone alignment)
    _accelSub = accelerometerEventStream(
      samplingPeriod: const Duration(microseconds: 10000), // 100 Hz target
    ).listen((event) {
      if (_isPaused) return;
      _rawAx = event.x;
      _rawAy = event.y;
      _rawAz = event.z;

      // Two-wheeler vibration dampening
      _filtAx = _filtAx * (1.0 - _filterAlpha) + _rawAx * _filterAlpha;
      _filtAy = _filtAy * (1.0 - _filterAlpha) + _rawAy * _filterAlpha;
      _filtAz = _filtAz * (1.0 - _filterAlpha) + _rawAz * _filterAlpha;

      _emitImu();
    });

    // 3. Subscribe to Gyroscope
    _gyroSub = gyroscopeEventStream(
      samplingPeriod: const Duration(microseconds: 10000), // 100 Hz target
    ).listen((event) {
      if (_isPaused) return;
      _filtGx = _filtGx * (1.0 - _filterAlpha) + event.x * _filterAlpha;
      _filtGy = _filtGy * (1.0 - _filterAlpha) + event.y * _filterAlpha;
      _filtGz = _filtGz * (1.0 - _filterAlpha) + event.z * _filterAlpha;
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
      // Magnetometer is optional
    }

    // 4. Subscribe to GNSS Location Stream
    if (_locationService != null) {
      _locSub = (_locationService.rawUpdates as Stream<loc.LocationData>).listen(_handleLocationData);
      if (_locationService.lastLocationData != null) {
        _handleLocationData(_locationService.lastLocationData as loc.LocationData);
      }
    } else {
      _locSub = _location.onLocationChanged.listen(_handleLocationData);
    }
  }

  void _handleLocationData(loc.LocationData locData) {
    if (_isPaused) return;
    final t = _getRelativeTimeSeconds();
    final accuracy = locData.accuracy ?? 10.0;
    final speed = (locData.speed != null && locData.speed! >= 0) ? locData.speed! : 0.0;
    final heading = locData.heading ?? 0.0;
    final lat = locData.latitude ?? 0.0;
    final lon = locData.longitude ?? 0.0;

    final isAvailable = (lat != 0.0 || lon != 0.0) && accuracy < 60.0;

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
        accuracy: loc.LocationAccuracy.navigation,
        interval: 1000, // 1 Hz navigation rate
        distanceFilter: 1.0, // 1 meter filter
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
      ax: _filtAx,
      ay: _filtAy,
      az: _filtAz,
      gx: _filtGx,
      gy: _filtGy,
      gz: _filtGz,
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
