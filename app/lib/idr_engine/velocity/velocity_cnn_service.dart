import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import '../filtering/imu_preprocessor.dart';

/// Service executing on-device VelocityCNN deep learning inference using TensorFlow Lite.
/// Takes 2.0s window of 100 Hz IMU data [1, 6, 200] and predicts forward vehicle velocity.
class VelocityCnnService {
  final String modelPath;
  tfl.Interpreter? _interpreter;
  bool _isLoaded = false;
  double _lastInferenceLatencyMs = 0.0;
  double _lastPredictedVelocity = 0.0;
  double _lastStationaryScore = 0.0;

  bool get isLoaded => _isLoaded;
  double get lastInferenceLatencyMs => _lastInferenceLatencyMs;
  double get lastPredictedVelocity => _lastPredictedVelocity;
  double get lastStationaryScore => _lastStationaryScore;

  VelocityCnnService({
    this.modelPath = 'assets/models/velocity_cnn.tflite',
  });

  Future<bool> initialize() async {
    try {
      final options = tfl.InterpreterOptions()..threads = 2;
      _interpreter = await tfl.Interpreter.fromAsset(modelPath, options: options);
      _interpreter?.allocateTensors();
      _isLoaded = true;
      debugPrint('VelocityCNN TFLite model successfully loaded from $modelPath');
      return true;
    } catch (e) {
      debugPrint('Warning: Could not load TFLite model ($e). Fallback estimator active.');
      _isLoaded = false;
      return false;
    }
  }

  /// Runs inference given the preprocessor's sliding window.
  /// Returns predicted forward velocity in m/s.
  (double velocity, double stationaryProb) predict(ImuPreprocessor preprocessor) {
    if (preprocessor.isStationary) {
      _lastPredictedVelocity = 0.0;
      _lastStationaryScore = 1.0;
      return (0.0, 1.0);
    }

    if (!_isLoaded || _interpreter == null || !preprocessor.isWindowReady) {
      // Fallback: estimate from forward acceleration and gyro
      return _runFallback(preprocessor);
    }

    final stopwatch = Stopwatch()..start();
    try {
      // Correct input tensor shape: [1, 6, 200]
      final inputTensor = preprocessor.getChannelsFirstTensor();

      // Output buffers
      final outputVelocity = List.filled(1, 0.0).reshape([1]);
      final outputStationary = List.filled(1, 0.0).reshape([1]);

      final outputs = {
        0: outputVelocity,
        1: outputStationary,
      };

      _interpreter!.runForMultipleInputs([inputTensor], outputs);

      stopwatch.stop();
      _lastInferenceLatencyMs = stopwatch.elapsedMicroseconds / 1000.0;

      final rawVelocity = (outputVelocity[0] as num).toDouble();
      final stationary = (outputStationary[0] as num).toDouble();

      // Ensure non-negative forward speed
      _lastPredictedVelocity = max(0.0, rawVelocity);
      _lastStationaryScore = stationary;

      return (_lastPredictedVelocity, _lastStationaryScore);
    } catch (e) {
      debugPrint('VelocityCNN inference error: $e');
      stopwatch.stop();
      return _runFallback(preprocessor);
    }
  }

  (double, double) _runFallback(ImuPreprocessor preprocessor) {
    // Kinematic fallback if TFLite interpreter is not available
    _lastPredictedVelocity = max(0.0, _lastPredictedVelocity);
    return (_lastPredictedVelocity, preprocessor.stationaryScore);
  }

  void reset() {
    _lastPredictedVelocity = 0.0;
    _lastStationaryScore = 0.0;
    _lastInferenceLatencyMs = 0.0;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
