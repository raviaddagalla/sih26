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

  /// IMU state and covariance propagation (100 Hz).
  void predict(double dt, Vector3 accel, Vector3 gyro) {
    if (dt <= 0 || dt > 0.2) dt = 0.01; // Protect against clock jumps

    // Correct IMU measurements with current bias estimates
    final aBody = accel - ba;
    final wBody = gyro - bg;

    final cBn = q.toRotationMatrix();

    // 1. Nominal State Propagation
    final aNed = cBn.multiplyVector(aBody) + g;
    p = p + (v * dt) + (aNed * (0.5 * dt * dt));
    v = v + (aNed * dt);

    final deltaQ = Quaternion.fromRotationVector(wBody * dt);
    q = q.multiply(deltaQ).normalized();

    // 2. Error State Transition Matrix F (15x15)
    // F = I_15 + F_continuous * dt
    final F = List<double>.filled(225, 0.0);
    for (int i = 0; i < 15; i++) {
      F[i * 15 + i] = 1.0; // Identity diagonal
    }

    // dp / dv = I * dt
    for (int i = 0; i < 3; i++) {
      F[i * 15 + (3 + i)] = dt;
    }

    // dv / dtheta = -C_bn * [a_b]x * dt
    final aBodySkew = aBody.skewSymmetric();
    final cbnSkew = cBn.multiply(aBodySkew);
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        F[(3 + r) * 15 + (6 + c)] = -cbnSkew.get(r, c) * dt;
        F[(3 + r) * 15 + (12 + c)] = -cBn.get(r, c) * dt; // dv / dba
      }
    }

    // dtheta / dtheta = I - [w_b]x * dt
    final wBodySkew = wBody.skewSymmetric();
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        F[(6 + r) * 15 + (6 + c)] -= wBodySkew.get(r, c) * dt;
        if (r == c) {
          F[(6 + r) * 15 + (9 + c)] = -dt; // dtheta / dbg
        }
      }
    }

    // 3. Covariance Propagation: P = F * P * F^T + Q_discrete
    final FP = _multiply15(F, P);
    final FPFt = _multiply15Transpose(FP, F);

    // Add process noise
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

  /// Update with Deep Learning forward velocity estimate.
  void updateMlVelocity(double vMl, double rMl) {
    final cBn = q.toRotationMatrix();
    final cNb = cBn.transpose();

    // Body velocity v_b = C_nb * v
    final vBody = cNb.multiplyVector(v);
    final zEst = vBody.x; // Forward body axis
    final y = vMl - zEst; // Innovation

    // Measurement Jacobian H (1x15)
    // dh / dv = cNb[0, :]
    // dh / dtheta = [v_b]x[0, :]
    final H = List<double>.filled(15, 0.0);
    H[3] = cNb.get(0, 0);
    H[4] = cNb.get(0, 1);
    H[5] = cNb.get(0, 2);

    final vBodySkew = vBody.skewSymmetric();
    H[6] = vBodySkew.get(0, 0);
    H[7] = vBodySkew.get(0, 1);
    H[8] = vBodySkew.get(0, 2);

    // S = H * P * H^T + R_ml (scalar)
    double HPHt = 0.0;
    final PHt = List<double>.filled(15, 0.0);
    for (int i = 0; i < 15; i++) {
      double sum = 0.0;
      for (int j = 0; j < 15; j++) {
        sum += _getP(i, j) * H[j];
      }
      PHt[i] = sum;
      HPHt += H[i] * sum;
    }

    final S = HPHt + rMl;
    if (S.abs() < 1e-9) return;
    final invS = 1.0 / S;

    // Kalman gain K = P * H^T * inv(S) (15x1)
    final dx = List<double>.filled(15, 0.0);
    for (int i = 0; i < 15; i++) {
      final ki = PHt[i] * invS;
      dx[i] = ki * y;
    }

    _injectErrorState(dx);

    // Update Covariance: P = (I - K*H) * P
    for (int i = 0; i < 15; i++) {
      final ki = PHt[i] * invS;
      for (int j = 0; j < 15; j++) {
        _setP(i, j, _getP(i, j) - ki * PHt[j]);
      }
    }
  }

  /// Non-Holonomic Constraints (NHC): Lateral and vertical velocity in body frame ~ 0.
  void updateNhc() {
    final cBn = q.toRotationMatrix();
    final cNb = cBn.transpose();
    final vBody = cNb.multiplyVector(v);

    // Constraint 1: Lateral velocity (Y) = 0
    _updateScalarMeasurement(
      hRow: [0, 0, 0, cNb.get(1, 0), cNb.get(1, 1), cNb.get(1, 2), 0, 0, 0, 0, 0, 0, 0, 0, 0],
      innovation: 0.0 - vBody.y,
      rVariance: 0.04, // 0.2 m/s std
    );

    // Constraint 2: Vertical velocity (Z) = 0
    _updateScalarMeasurement(
      hRow: [0, 0, 0, cNb.get(2, 0), cNb.get(2, 1), cNb.get(2, 2), 0, 0, 0, 0, 0, 0, 0, 0, 0],
      innovation: 0.0 - vBody.z,
      rVariance: 0.04,
    );
  }

  /// Zero Velocity Update (ZUPT): When stationary, v = 0.
  void updateZupt() {
    for (int axis = 0; axis < 3; axis++) {
      final h = List<double>.filled(15, 0.0);
      h[3 + axis] = 1.0;
      final currentV = axis == 0 ? v.x : (axis == 1 ? v.y : v.z);
      _updateScalarMeasurement(
        hRow: h,
        innovation: 0.0 - currentV,
        rVariance: 0.0025, // 0.05 m/s tight uncertainty
      );
    }
  }

  /// GNSS position update with reported horizontal accuracy.
  void updateGnss(double lat, double lon, double accuracy) {
    final ned = GeoUtils.latLonToNed(lat, lon, originLat, originLon);
    final variance = max(accuracy * accuracy, 2.25); // At least 1.5m std

    // North update
    _updateScalarMeasurement(
      hRow: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      innovation: ned.x - p.x,
      rVariance: variance,
    );

    // East update
    _updateScalarMeasurement(
      hRow: [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      innovation: ned.y - p.y,
      rVariance: variance,
    );
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
