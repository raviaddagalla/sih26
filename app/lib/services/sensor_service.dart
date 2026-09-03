import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../models/navigation_models.dart';

class SensorService {
  final _windows = StreamController<List<SensorSample>>.broadcast();
  final _rawData = StreamController<String>.broadcast();
  final List<SensorSample> _buffer = <SensorSample>[];
  StreamSubscription<AccelerometerEvent>? _accelerometer;
  StreamSubscription<GyroscopeEvent>? _gyroscope;
  AccelerometerEvent? _lastAcceleration;
  GyroscopeEvent? _lastGyroscope;

  Stream<List<SensorSample>> get windows => _windows.stream;
  Stream<String> get rawData => _rawData.stream;

  void start() {
    _accelerometer = accelerometerEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
      _lastAcceleration = event;
      _pushIfReady();
      _rawData.add('ACC: ${event.x.toStringAsFixed(2)}, ${event.y.toStringAsFixed(2)}, ${event.z.toStringAsFixed(2)}');
    });
    _gyroscope = gyroscopeEventStream(samplingPeriod: const Duration(milliseconds: 10)).listen((event) {
      _lastGyroscope = event;
      _pushIfReady();
    });
  }

  void stop() {
    _accelerometer?.cancel();
    _gyroscope?.cancel();
    _buffer.clear();
  }

  void _pushIfReady() {
    if (_lastAcceleration == null || _lastGyroscope == null) return;
    
    final a = _lastAcceleration!;
    final g = _lastGyroscope!;
    _buffer.add(SensorSample(ax: a.x, ay: a.y, az: a.z, gx: g.x, gy: g.y, gz: g.z, timestamp: DateTime.now()));
    
    _lastAcceleration = null;
    _lastGyroscope = null;

    if (_buffer.length >= 200) {
      _windows.add(List.of(_buffer));
      _buffer.clear();
    }
  }

  void dispose() {
    _accelerometer?.cancel();
    _gyroscope?.cancel();
    _windows.close();
    _rawData.close();
  }
}
