import 'dart:math';
import '../core/math_utils.dart';

/// 15-State Error-State Kalman Filter (ESKF) for 3D Navigation.
/// State vector:
/// - Position p (North, East, Down) [3]
/// - Velocity v (NED) [3]
/// - Attitude q (quaternion Body -> NED) [4]
/// - Gyroscope bias bg [3]
/// - Accelerometer bias ba [3]
class ESKF {
  final double originLat;
  final double originLon;

  Vector3 p = Vector3.zero;
  Vector3 v = Vector3.zero;
  Quaternion q = Quaternion.identity;
  Vector3 bg = Vector3.zero;
  Vector3 ba = Vector3.zero;

  static const g = Vector3(0.0, 0.0, 9.81); // Gravity in NED

  // 15x15 Error Covariance Matrix P stored as flat list of 225 doubles
  late List<double> P;

  // Process noise parameters
  final double accelNoise;
  final double gyroNoise;
  final double accelBiasWalk;
  final double gyroBiasWalk;

  double forwardSpeed = 0.0;
  bool _isInitialFix = true;

  ESKF({
    required this.originLat,
    required this.originLon,
    double initHeadingRad = 0.0,
    double initSpeed = 0.0,
    this.accelNoise = 0.1,
    this.gyroNoise = 0.01,
    this.accelBiasWalk = 0.001,
    this.gyroBiasWalk = 0.0001,
  }) {
    p = Vector3.zero;
    forwardSpeed = initSpeed;
    v = Vector3(
      initSpeed * cos(initHeadingRad),
      initSpeed * sin(initHeadingRad),
      0.0,
    );
    q = Quaternion.fromEuler(initHeadingRad, 0.0, 0.0);

    // Initialize 15x15 Covariance
    P = List<double>.filled(225, 0.0);
    for (int i = 0; i < 15; i++) {
      if (i < 3) {
        _setP(i, i, 4.0); // 2m position initial uncertainty
      } else if (i < 6) {
        _setP(i, i, 1.0); // 1 m/s velocity initial uncertainty
      } else if (i < 9) {
        _setP(i, i, (pi / 6) * (pi / 6)); // heading uncertainty
      } else if (i < 12) {
        _setP(i, i, 1e-4); // gyro bias
      } else {
        _setP(i, i, 1e-3); // accel bias
      }
    }
  }

  double _getP(int r, int c) => P[r * 15 + c];
  void _setP(int r, int c, double val) {
    P[r * 15 + c] = val;
  }

  /// IMU state propagation (100 Hz).
  /// Uses vehicular non-holonomic kinematics to eliminate accelerometer double-integration
  /// divergence under intense engine vibrations (e.g. scooters / two-wheelers).
  void predict(double dt, Vector3 accel, Vector3 gyro) {
    if (dt <= 0 || dt > 0.2) dt = 0.01; // Protect against clock jumps

    // Correct IMU measurements with current bias estimates
    final aBody = accel - ba;
    final wBody = gyro - bg;

    // 1. Attitude Propagation: Gyroscope integration (immune to linear vibrations and gravity leak)
    final deltaQ = Quaternion.fromRotationVector(wBody * dt);
    q = q.multiply(deltaQ).normalized();

    // 2. Extract current vehicle heading (yaw)
    final yaw = q.toEuler().x;

    // 3. Smooth forward speed with along-track acceleration bounded against vibration spikes
    final aForward = (aBody.x).clamp(-3.5, 3.5);
    forwardSpeed = (forwardSpeed + aForward * dt).clamp(0.0, 45.0);

    // 4. Vehicular non-holonomic velocity (lateral and vertical velocity = 0)
    v = Vector3(
      forwardSpeed * cos(yaw),
      forwardSpeed * sin(yaw),
      0.0,
    );

    // 5. Kinematic position propagation (single integration of velocity)
    p = p + (v * dt);

    // 6. Error State Transition Matrix F (15x15)
    final F = List<double>.filled(225, 0.0);
    for (int i = 0; i < 15; i++) {
      F[i * 15 + i] = 1.0;
    }
    for (int i = 0; i < 3; i++) {
      F[i * 15 + (3 + i)] = dt;
    }

    final cBn = q.toRotationMatrix();
    final aBodySkew = aBody.skewSymmetric();
    final cbnSkew = cBn.multiply(aBodySkew);
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        F[(3 + r) * 15 + (6 + c)] = -cbnSkew.get(r, c) * dt;
      }
    }

    // 7. Covariance Propagation: P = F * P * F^T + Q
    final FP = _multiply15(F, P);
    final FPFt = _multiply15Transpose(FP, F);

    final qA = accelNoise * accelNoise * dt;
    final qG = gyroNoise * gyroNoise * dt;
    final qBa = accelBiasWalk * accelBiasWalk * dt;
    final qBg = gyroBiasWalk * gyroBiasWalk * dt;

    for (int i = 0; i < 3; i++) {
      FPFt[(3 + i) * 15 + (3 + i)] += qA;
      FPFt[(6 + i) * 15 + (6 + i)] += qG;
      FPFt[(9 + i) * 15 + (9 + i)] += qBg;
      FPFt[(12 + i) * 15 + (12 + i)] += qBa;
    }

    P = FPFt;
  }

  /// Update with Deep Learning forward velocity estimate (VelocityCNN).
  void updateMlVelocity(double vMl, double rMl) {
    if (vMl < 0) return;
    // Adaptively blend forward speed towards AI estimate
    final innov = vMl - forwardSpeed;
    final k = 0.30;
    forwardSpeed = max(0.0, forwardSpeed + k * innov);

    final yaw = q.toEuler().x;
    v = Vector3(
      forwardSpeed * cos(yaw),
      forwardSpeed * sin(yaw),
      0.0,
    );
  }

  /// Non-Holonomic Constraints (NHC): Lateral and vertical velocity in body frame ~ 0.
  void updateNhc() {
    final yaw = q.toEuler().x;
    v = Vector3(
      forwardSpeed * cos(yaw),
      forwardSpeed * sin(yaw),
      0.0,
    );
  }

  /// Zero Velocity Update (ZUPT): When stationary, vehicle speed is locked to zero.
  void updateZupt() {
    forwardSpeed = 0.0;
    v = Vector3.zero;
  }

  /// GNSS position and velocity update.
  /// Anchors local position and resets accumulated drift cleanly.
  void updateGnss(
    double lat,
    double lon,
    double accuracy, {
    double? speed,
    double? heading,
  }) {
    final ned = GeoUtils.latLonToNed(lat, lon, originLat, originLon);
    final errorDist = sqrt((ned.x - p.x) * (ned.x - p.x) + (ned.y - p.y) * (ned.y - p.y));

    if (errorDist > 25.0 || _isInitialFix) {
      // Cleanly anchor position on initial fix or large gap without lag
      p = Vector3(ned.x, ned.y, p.z);
      _isInitialFix = false;
    } else {
      // Smooth Kalman innovation
      final variance = max(accuracy * accuracy, 2.25);
      final k = (10.0 / (10.0 + variance)).clamp(0.20, 0.75);
      p = Vector3(
        p.x + k * (ned.x - p.x),
        p.y + k * (ned.y - p.y),
        p.z,
      );
    }

    // Update forward speed if GNSS speed is reliable
    if (speed != null && speed >= 0.5) {
      forwardSpeed = speed;
      final yaw = q.toEuler().x;
      v = Vector3(
        forwardSpeed * cos(yaw),
        forwardSpeed * sin(yaw),
        0.0,
      );
    }

    // Align yaw with GNSS course over ground when vehicle is in steady forward motion
    if (heading != null && speed != null && speed > 2.5) {
      final currentYawDeg = headingDegrees;
      final diffDeg = GeoUtils.wrapDegrees(heading - currentYawDeg);
      if (diffDeg.abs() < 45.0) {
        final nudgeRad = (diffDeg * 0.12) * pi / 180.0;
        final corrQ = Quaternion.fromEuler(nudgeRad, 0.0, 0.0);
        q = q.multiply(corrQ).normalized();
      }
    }
  }

  void _updateScalarMeasurement({
    required List<double> hRow,
    required double innovation,
    required double rVariance,
  }) {
    // PHt = P * H^T
    final PHt = List<double>.filled(15, 0.0);
    double HPHt = 0.0;
    for (int i = 0; i < 15; i++) {
      double sum = 0.0;
      for (int j = 0; j < 15; j++) {
        sum += _getP(i, j) * hRow[j];
      }
      PHt[i] = sum;
      HPHt += hRow[i] * sum;
    }

    final S = HPHt + rVariance;
    if (S.abs() < 1e-12) return;
    final invS = 1.0 / S;

    final dx = List<double>.filled(15, 0.0);
    for (int i = 0; i < 15; i++) {
      dx[i] = PHt[i] * invS * innovation;
    }

    _injectErrorState(dx);

    // Covariance update: P = P - K * (H * P) = P - (P * H^T) * (P * H^T)^T / S
    for (int i = 0; i < 15; i++) {
      for (int j = 0; j < 15; j++) {
        _setP(i, j, _getP(i, j) - PHt[i] * PHt[j] * invS);
      }
    }
  }

  void _injectErrorState(List<double> dx) {
    p = Vector3(p.x + dx[0], p.y + dx[1], p.z + dx[2]);
    v = Vector3(v.x + dx[3], v.y + dx[4], v.z + dx[5]);

    // Orientation error: dq = [0.5 * dtheta, 1.0]
    final dTheta = Vector3(dx[6], dx[7], dx[8]);
    final dq = Quaternion.fromRotationVector(dTheta);
    q = q.multiply(dq).normalized();

    bg = Vector3(bg.x + dx[9], bg.y + dx[10], bg.z + dx[11]);
    ba = Vector3(ba.x + dx[12], ba.y + dx[13], ba.z + dx[14]);
  }

  (double lat, double lon) getLatLon() {
    return GeoUtils.nedToLatLon(p.x, p.y, originLat, originLon);
  }

  double get headingDegrees {
    final euler = q.toEuler();
    var deg = euler.x * 180.0 / pi;
    if (deg < 0) deg += 360.0;
    return deg;
  }

  double get speed => v.norm;

  double get positionUncertainty => sqrt(_getP(0, 0) + _getP(1, 1));

  // 15x15 Matrix Multiplication Helpers
  List<double> _multiply15(List<double> A, List<double> B) {
    final C = List<double>.filled(225, 0.0);
    for (int r = 0; r < 15; r++) {
      final rOffset = r * 15;
      for (int c = 0; c < 15; c++) {
        double sum = 0.0;
        for (int k = 0; k < 15; k++) {
          sum += A[rOffset + k] * B[k * 15 + c];
        }
        C[rOffset + c] = sum;
      }
    }
    return C;
  }

  List<double> _multiply15Transpose(List<double> A, List<double> B) {
    // Computes A * B^T
    final C = List<double>.filled(225, 0.0);
    for (int r = 0; r < 15; r++) {
      final rOffset = r * 15;
      for (int c = 0; c < 15; c++) {
        final cOffset = c * 15;
        double sum = 0.0;
        for (int k = 0; k < 15; k++) {
          sum += A[rOffset + k] * B[cOffset + k];
        }
        C[rOffset + c] = sum;
      }
    }
    return C;
  }
}
