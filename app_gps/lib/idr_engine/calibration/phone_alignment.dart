import 'dart:math';
import '../core/math_utils.dart';
import '../core/imu_sample.dart';

/// Estimates and applies 3D transformation between phone mounting frame
/// and vehicle reference frame (Forward-X, Right-Y, Down-Z).
class PhoneAlignment {
  Matrix3 _rotationGravity = Matrix3.identity();
  Matrix3 _rotationYaw = Matrix3.identity();
  Matrix3 _rotationCombined = Matrix3.identity();

  bool _isGravityCalibrated = false;
  bool _isYawCalibrated = false;
  double _yawOffsetRad = 0.0;

  final List<Vector3> _stationaryAccelBuffer = [];
  final List<double> _headingDifferences = [];
  int _consecutiveOutliers = 0;

  bool get isCalibrated => _isGravityCalibrated;
  bool get isGravityCalibrated => _isGravityCalibrated;
  bool get isYawCalibrated => _isYawCalibrated;
  bool get isFullyCalibrated => _isGravityCalibrated && _isYawCalibrated;
  int get stationarySampleCount => _stationaryAccelBuffer.length;
  int get yawSampleCount => _headingDifferences.length;
  double get yawOffsetDegrees => _yawOffsetRad * 180.0 / pi;
  double get roll => atan2(_rotationCombined.m[7], _rotationCombined.m[8]);
  double get pitch => -asin(_rotationCombined.m[6].clamp(-1.0, 1.0));

  /// Accumulate raw accelerometer samples during stationary periods to estimate gravity.
  void addStationarySample(Vector3 rawAccel) {
    if (_isGravityCalibrated) return;
    _stationaryAccelBuffer.add(rawAccel);
    if (_stationaryAccelBuffer.length >= 50) {
      // 50 samples (~0.5s at 100Hz)
      _computeGravityAlignment();
    }
  }

  void _computeGravityAlignment() {
    double sumX = 0, sumY = 0, sumZ = 0;
    for (final a in _stationaryAccelBuffer) {
      sumX += a.x;
      sumY += a.y;
      sumZ += a.z;
    }
    final n = _stationaryAccelBuffer.length;
    final gMean = Vector3(sumX / n, sumY / n, sumZ / n);
    final gNorm = gMean.norm;
    if (gNorm < 1e-4) return;

    final gUnit = gMean.normalized();
    final targetZ = const Vector3(0.0, 0.0, -1.0); // stationary accel (~+g, points up) -> -Z, so Z is down

    // Axis of rotation: v = gUnit x targetZ
    final v = gUnit.cross(targetZ);
    final s = v.norm;
    final c = gUnit.dot(targetZ);

    if (s < 1e-6) {
      _rotationGravity = c > 0 ? Matrix3.identity() : Matrix3.diag(1.0, -1.0, -1.0);
    } else {
      // Rodrigues formula: R = I + [v]x + [v]x^2 * (1-c)/s^2
      final vx = v.skewSymmetric();
      final vx2 = vx.multiply(vx);
      final factor = (1.0 - c) / (s * s);

      final eye = Matrix3.identity();
      _rotationGravity = eye + vx + (vx2 * factor);
    }

    _isGravityCalibrated = true;
    _updateCombinedRotation();
  }

  /// Correlates GPS heading with phone integrated yaw during forward motion (>1.8 m/s).
  /// Features adaptive discontinuity / phone bump detection: if heading residual
  /// jumps by >25° persistently, the buffer is cleared to recalibrate rapidly in a burst.
  void updateYawOffset(double gpsHeadingDeg, double phoneYawDeg, double speed) {
    if (speed < 1.8) return; // Calibrate yaw during any forward motion (> 6.5 km/h)

    final diff = GeoUtils.wrapDegrees(gpsHeadingDeg - phoneYawDeg);

    // Bump / remount detection: if heading shifts suddenly while vehicle moves straight
    if (_isYawCalibrated) {
      final currentYawOffsetDeg = _yawOffsetRad * 180.0 / pi;
      final residual = (GeoUtils.wrapDegrees(diff - currentYawOffsetDeg)).abs();

      if (residual > 25.0) {
        _consecutiveOutliers++;
        if (_consecutiveOutliers >= 3) {
          // Discontinuity confirmed: phone was bumped or remounted
          _headingDifferences.clear();
          _consecutiveOutliers = 0;
          _isYawCalibrated = false;
        }
      } else {
        _consecutiveOutliers = 0;
      }
    }

    _headingDifferences.add(diff);
    if (_headingDifferences.length > 20) {
      _headingDifferences.removeAt(0);
    }

    // Converges in fast burst mode with >= 3 samples, or normal mode with >= 5 samples
    final minSamples = _isYawCalibrated ? 5 : 3;
    if (_headingDifferences.length >= minSamples) {
      final sorted = List<double>.from(_headingDifferences)..sort();
      final medianDiff = sorted[sorted.length ~/ 2];
      _yawOffsetRad = medianDiff * pi / 180.0;

      final cy = cos(_yawOffsetRad);
      final sy = sin(_yawOffsetRad);
      _rotationYaw = Matrix3([
        cy, -sy, 0.0,
        sy, cy, 0.0,
        0.0, 0.0, 1.0,
      ]);

      _isYawCalibrated = true;
      _updateCombinedRotation();
    }
  }

  void _updateCombinedRotation() {
    _rotationCombined = _rotationYaw.multiply(_rotationGravity);
  }

  /// Transforms phone IMU sample into vehicle frame.
  ImuSample transform(ImuSample phoneSample) {
    if (!_isGravityCalibrated) return phoneSample;

    final rawA = Vector3(phoneSample.ax, phoneSample.ay, phoneSample.az);
    final rawG = Vector3(phoneSample.gx, phoneSample.gy, phoneSample.gz);

    final vehA = _rotationCombined.multiplyVector(rawA);
    final vehG = _rotationCombined.multiplyVector(rawG);

    return ImuSample(
      timestamp: phoneSample.timestamp,
      ax: vehA.x,
      ay: vehA.y,
      az: vehA.z,
      gx: vehG.x,
      gy: vehG.y,
      gz: vehG.z,
      mx: phoneSample.mx,
      my: phoneSample.my,
      mz: phoneSample.mz,
    );
  }

  void reset() {
    _rotationGravity = Matrix3.identity();
    _rotationYaw = Matrix3.identity();
    _rotationCombined = Matrix3.identity();
    _isGravityCalibrated = false;
    _isYawCalibrated = false;
    _yawOffsetRad = 0.0;
    _consecutiveOutliers = 0;
    _stationaryAccelBuffer.clear();
    _headingDifferences.clear();
  }
}
