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

  bool get isCalibrated => _isGravityCalibrated;
  bool get isYawCalibrated => _isYawCalibrated;
  double get yawOffsetDegrees => _yawOffsetRad * 180.0 / pi;

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
    final targetZ = const Vector3(0.0, 0.0, 1.0); // Gravity aligns with +Z in NED

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

  /// Correlates GPS heading with phone integrated yaw during forward motion (>3 m/s).
  void updateYawOffset(double gpsHeadingDeg, double phoneYawDeg, double speed) {
    if (speed < 3.0) return; // Only calibrate yaw when moving steadily forward

    final diff = GeoUtils.wrapDegrees(gpsHeadingDeg - phoneYawDeg);
    _headingDifferences.add(diff);
    if (_headingDifferences.length > 20) {
      _headingDifferences.removeAt(0);
    }

    if (_headingDifferences.length >= 5) {
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
    _stationaryAccelBuffer.clear();
    _headingDifferences.clear();
  }
}
