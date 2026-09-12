/// Continual on-device personalization adapter.
/// Solves an online Recursive Least Squares (RLS) calibration between raw AI velocity
/// and high-confidence GNSS ground truth to personalize inference for individual phone mounting
/// angles, tire wear, and vehicle suspension profiles without requiring backpropagation.
class OnlineVelocityCalibrator {
  double _scale = 1.0;
  double _bias = 0.0;
  int _calibratedSampleCount = 0;

  double get scale => _scale;
  double get bias => _bias;
  int get sampleCount => _calibratedSampleCount;
  bool get hasSufficientSamples => _calibratedSampleCount >= 50;

  // Covariance matrix for parameter vector theta = [scale, bias]^T
  double _p00 = 10.0;
  double _p01 = 0.0;
  double _p10 = 0.0;
  double _p11 = 10.0;

  // Forgetting factor (slow adaptation to tire wear and mount shift)
  static const double _lambda = 0.998;

  void reset() {
    _scale = 1.0;
    _bias = 0.0;
    _calibratedSampleCount = 0;
    _p00 = 10.0;
    _p01 = 0.0;
    _p10 = 0.0;
    _p11 = 10.0;
  }

  /// Ingests paired observation during strong GNSS fixes.
  void updateObservation({
    required double modelVelocity,
    required double gnssVelocity,
    required double gnssAccuracy,
  }) {
    // Gate: only update when vehicle is moving and GPS accuracy is high
    if (modelVelocity < 2.5 || gnssVelocity < 2.5 || gnssAccuracy > 3.0) {
      return;
    }

    final x0 = modelVelocity;
    const x1 = 1.0;

    // Predicted GNSS speed using current calibration
    final yPred = _scale * x0 + _bias * x1;
    final error = gnssVelocity - yPred;

    // Gain vector K = P * x / (lambda + x^T * P * x)
    final px0 = _p00 * x0 + _p01 * x1;
    final px1 = _p10 * x0 + _p11 * x1;
    final denom = _lambda + (x0 * px0 + x1 * px1);

    if (denom.abs() < 1e-6) return;

    final k0 = px0 / denom;
    final k1 = px1 / denom;

    // Update parameters
    _scale += k0 * error;
    _bias += k1 * error;

    // Physically bounded clamps to prevent runaway divergence
    _scale = _scale.clamp(0.75, 1.25);
    _bias = _bias.clamp(-1.5, 1.5);

    // Update covariance P = (P - K * x^T * P) / lambda
    _p00 = (_p00 - k0 * px0) / _lambda;
    _p01 = (_p01 - k0 * px1) / _lambda;
    _p10 = (_p10 - k1 * px0) / _lambda;
    _p11 = (_p11 - k1 * px1) / _lambda;

    _calibratedSampleCount++;
  }

  /// Calibrates an AI velocity prediction using the continually trained parameters.
  double calibrate(double rawVelocity) {
    if (rawVelocity <= 0.1) return 0.0;
    final calibrated = (_scale * rawVelocity) + _bias;
    return calibrated < 0.0 ? 0.0 : calibrated;
  }
}
