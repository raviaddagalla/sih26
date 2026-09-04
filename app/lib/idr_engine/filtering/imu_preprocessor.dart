import 'dart:math';
import '../core/imu_sample.dart';

/// Preprocesses high-frequency IMU measurements:
/// - Low-pass vibration filtering
/// - Zero-Velocity Update (ZUPT) detection
/// - Normalization and sliding window assembly for VelocityCNN
class ImuPreprocessor {
  // Low-pass filter smoothing factors (exponential moving average: alpha ~ 0.35 at 100Hz)
  final double alpha;
  double _filteredAx = 0, _filteredAy = 0, _filteredAz = 0;
  double _filteredGx = 0, _filteredGy = 0, _filteredGz = 0;
  bool _initialized = false;

  // Sliding window buffer for VelocityCNN (200 timesteps)
  static const int windowSize = 200;
  final List<List<double>> _windowBuffer = [];

  // Normalization parameters from norm_params.json
  final List<double> means;
  final List<double> stds;

  // ZUPT state
  bool _isStationary = false;
  double _stationaryScore = 0.0;
  final List<double> _accelMagBuffer = [];

  bool get isStationary => _isStationary;
  double get stationaryScore => _stationaryScore;
  bool get isWindowReady => _windowBuffer.length >= windowSize;

  ImuPreprocessor({
    this.alpha = 0.35,
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
      // Exponential low-pass filter
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

    // Check ZUPT (Zero-Velocity Update) condition
    final accelMag = sqrt(sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az);
    _accelMagBuffer.add(accelMag);
    if (_accelMagBuffer.length > 25) {
      _accelMagBuffer.removeAt(0);
    }

    if (_accelMagBuffer.length >= 20) {
      double sum = 0;
      for (final m in _accelMagBuffer) {
        sum += m;
      }
      final meanMag = sum / _accelMagBuffer.length;
      double varSum = 0;
      for (final m in _accelMagBuffer) {
        varSum += (m - meanMag) * (m - meanMag);
      }
      final variance = varSum / _accelMagBuffer.length;
      final gyroEnergy = sample.gx * sample.gx + sample.gy * sample.gy + sample.gz * sample.gz;

      // When vehicle is completely stationary, variance and gyro energy are minimal
      _isStationary = (variance < 0.05 && gyroEnergy < 0.005);
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

  /// Builds a [1, 6, 20] tensor for 20-sample window model if needed.
  List<List<List<double>>> getChannelsFirstTensor20() {
    final int count = min(20, _windowBuffer.length);
    final startIndex = _windowBuffer.length - count;

    final tensor = List.generate(
      1,
      (_) => List.generate(
        6,
        (channelIdx) => List.generate(
          20,
          (step) {
            final idx = (startIndex + step).clamp(0, _windowBuffer.length - 1);
            return _windowBuffer[idx][channelIdx];
          },
        ),
      ),
    );
    return tensor;
  }

  void reset() {
    _initialized = false;
    _windowBuffer.clear();
    _accelMagBuffer.clear();
    _isStationary = false;
    _stationaryScore = 0.0;
  }
}
