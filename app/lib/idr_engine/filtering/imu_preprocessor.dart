import 'dart:math';
import '../core/imu_sample.dart';

/// Preprocesses high-frequency IMU measurements:
/// - Engine vibration suppression
/// - Adaptive Zero-Velocity Update (ZUPT) detection for two-wheelers/scooters
/// - Normalization and sliding window assembly for VelocityCNN
class ImuPreprocessor {
  // Cascaded low-pass filter (alpha ~ 0.15 gives a ~3.5 Hz cutoff at 100Hz, killing engine buzz)
  final double alpha;
  double _filteredAx = 0, _filteredAy = 0, _filteredAz = 9.81;
  double _filteredGx = 0, _filteredGy = 0, _filteredGz = 0;
  bool _initialized = false;

  // Sliding window buffer for VelocityCNN (200 timesteps = 2.0s @ 100Hz)
  static const int windowSize = 200;
  final List<List<double>> _windowBuffer = [];

  // Normalization parameters from norm_params.json
  final List<double> means;
  final List<double> stds;

  // Adaptive ZUPT state
  bool _isStationary = false;
  double _stationaryScore = 0.0;
  final List<double> _gyroNormBuffer = [];

  bool get isStationary => _isStationary;
  double get stationaryScore => _stationaryScore;
  bool get isWindowReady => _windowBuffer.length >= windowSize;

  ImuPreprocessor({
    this.alpha = 0.15,
    List<double>? means,
    List<double>? stds,
  })  : means = means ??
            [
              -0.009899024852638716,
              -0.0021339575185084186,
              0.031720713589235526,
              7.011283574844645e-05,
              0.0032069419290166132,
              0.0001758348647584805,
            ],
        stds = stds ??
            [
              1.0818546074690019,
              0.7255807936802988,
              1.0966175084916605,
              0.14618253494870068,
              0.1058484141084515,
              0.0792430138368888,
            ];

  /// Process an incoming IMU sample. Returns low-pass filtered sample.
  ImuSample process(ImuSample sample) {
    if (!_initialized) {
      _filteredAx = sample.ax;
      _filteredAy = sample.ay;
      _filteredAz = sample.az;
      _filteredGx = sample.gx;
      _filteredGy = sample.gy;
      _filteredGz = sample.gz;
      _initialized = true;
    } else {
      // Exponential low-pass filter (quenches engine vibration harmonics)
      _filteredAx = _filteredAx * (1 - alpha) + sample.ax * alpha;
      _filteredAy = _filteredAy * (1 - alpha) + sample.ay * alpha;
      _filteredAz = _filteredAz * (1 - alpha) + sample.az * alpha;
      _filteredGx = _filteredGx * (1 - alpha) + sample.gx * alpha;
      _filteredGy = _filteredGy * (1 - alpha) + sample.gy * alpha;
      _filteredGz = _filteredGz * (1 - alpha) + sample.gz * alpha;
    }

    // Normalized sample: [ax, ay, az, gx, gy, gz]
    final normValues = [
      (_filteredAx - means[0]) / stds[0],
      (_filteredAy - means[1]) / stds[1],
      (_filteredAz - means[2]) / stds[2],
      (_filteredGx - means[3]) / stds[3],
      (_filteredGy - means[4]) / stds[4],
      (_filteredGz - means[5]) / stds[5],
    ];

    _windowBuffer.add(normValues);
    if (_windowBuffer.length > windowSize) {
      _windowBuffer.removeAt(0);
    }

    // Adaptive ZUPT: When vehicle is stopped at a signal or parking,
    // filtered angular rate is very small even if the single-cylinder engine idles
    final gyroNorm = sqrt(_filteredGx * _filteredGx + _filteredGy * _filteredGy + _filteredGz * _filteredGz);
    _gyroNormBuffer.add(gyroNorm);
    if (_gyroNormBuffer.length > 50) {
      _gyroNormBuffer.removeAt(0);
    }

    if (_gyroNormBuffer.length >= 30) {
      double sumG = 0;
      for (final g in _gyroNormBuffer) {
        sumG += g;
      }
      final meanG = sumG / _gyroNormBuffer.length;

      // When stopped (even with scooter idling), mean low-pass gyro rate < 0.06 rad/s (~3.4 deg/s)
      _isStationary = meanG < 0.06;
      _stationaryScore = _isStationary ? 1.0 : 0.0;
    }

    return ImuSample(
      timestamp: sample.timestamp,
      ax: _filteredAx,
      ay: _filteredAy,
      az: _filteredAz,
      gx: _filteredGx,
      gy: _filteredGy,
      gz: _filteredGz,
      mx: sample.mx,
      my: sample.my,
      mz: sample.mz,
    );
  }

  /// Builds a [1, 6, 200] channels-first tensor for VelocityCNN inference.
  List<List<List<double>>> getChannelsFirstTensor() {
    assert(isWindowReady);

    // Shape: [1, 6, 200]
    final tensor = List.generate(
      1,
      (_) => List.generate(
        6,
        (channelIdx) => List.generate(
          windowSize,
          (timeIdx) => _windowBuffer[timeIdx][channelIdx],
        ),
      ),
    );
    return tensor;
  }

  void reset() {
    _initialized = false;
    _windowBuffer.clear();
    _gyroNormBuffer.clear();
    _isStationary = false;
    _stationaryScore = 0.0;
  }
}
