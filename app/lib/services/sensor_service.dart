import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../models/navigation_models.dart';

class SensorService {
  final _windows = StreamController<List<SensorSample>>.broadcast();
  final List<SensorSample> _buffer = <SensorSample>[];
  StreamSubscription<AccelerometerEvent>? _accelerometer;
  StreamSubscription<GyroscopeEvent>? _gyroscope;
  AccelerometerEvent? _lastAcceleration;
  GyroscopeEvent? _lastGyroscope;

  Stream<List<SensorSample>> get windows => _windows.stream;

  void start() {
    _accelerometer = accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
      _lastAcceleration = event;
      _pushIfReady();
    });
    _gyroscope = gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
      _lastGyroscope = event;
      _pushIfReady();
    });
  }

  void _pushIfReady() {
    final a = _lastAcceleration;
    final g = _lastGyroscope;
    if (a == null || g == null) return;
    _buffer.add(SensorSample(ax: a.x, ay: a.y, az: a.z, gx: g.x, gy: g.y, gz: g.z, timestamp: DateTime.now()));
    if (_buffer.length > 200) _buffer.removeAt(0);
    if (_buffer.length == 200) _windows.add(List.unmodifiable(_buffer));
  }

  void dispose() {
    _accelerometer?.cancel();
    _gyroscope?.cancel();
    _windows.close();
  }
}
