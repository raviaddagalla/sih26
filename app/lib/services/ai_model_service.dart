import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/navigation_models.dart';

class AiModelService {
  AiModelService({this.modelAsset = 'assets/models/velocity_cnn.tflite', this.normAsset = 'assets/models/norm_params.json'});

  final String modelAsset;
  final String normAsset;
  Interpreter? _interpreter;
  List<double> _means = const [];
  List<double> _stds = const [];

  bool get isReady => _interpreter != null;

  Future<void> load() async {
    _interpreter = await Interpreter.fromAsset(modelAsset);
    final raw = jsonDecode(await rootBundle.loadString(normAsset)) as Map<String, dynamic>;
    _means = (raw['means'] as List).cast<num>().map((v) => v.toDouble()).toList();
    _stds = (raw['stds'] as List).cast<num>().map((v) => v.toDouble()).toList();
  }

  Future<double> predictVelocityKmh(List<SensorSample> window) async {
    final interpreter = _interpreter;
    if (interpreter == null || window.length < 200) return 0;
    // The converted TFLite graph expects [batch, time, channels] = [1, 200, 6].
    final input = List.generate(1, (_) => List.generate(200, (time) => List.generate(6, (channel) {
      final sample = window[window.length - 200 + time];
      final raw = switch (channel) {
        0 => sample.ax,
        1 => sample.ay,
        2 => sample.az,
        3 => sample.gx,
        4 => sample.gy,
        _ => sample.gz,
      };
      return (raw - _means[channel]) / _stds[channel];
    })));
    final outputs = [List.filled(1, 0.0), List.filled(1, 0.0)];
    interpreter.runForMultipleInputs([input], {0: outputs[0], 1: outputs[1]});
    return (outputs[0][0] as num).toDouble() * 3.6;
  }

  void close() {
    _interpreter?.close();
    _interpreter = null;
  }
}
