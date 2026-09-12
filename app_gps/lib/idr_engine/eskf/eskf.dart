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
    final fp = _multiply15(F, P);
    final fpFt = _multiply15Transpose(fp, F);

    final qScale = processNoiseScale;
    final qA = accelNoise * accelNoise * dt * qScale;
    final qG = gyroNoise * gyroNoise * dt * qScale;
    final qBa = accelBiasWalk * accelBiasWalk * dt * qScale;
    final qBg = gyroBiasWalk * gyroBiasWalk * dt * qScale;

    for (int i = 0; i < 3; i++) {
      fpFt[(3 + i) * 15 + (3 + i)] += qA;
      fpFt[(6 + i) * 15 + (6 + i)] += qG;
      fpFt[(9 + i) * 15 + (9 + i)] += qBg;
      fpFt[(12 + i) * 15 + (12 + i)] += qBa;
    }

    P = fpFt;
    _symmetrizeP();
  }

  /// Dynamic scale for process noise Q (e.g. pre-tightening during tunnel approach)
  double processNoiseScale = 1.0;

  void scaleProcessNoise(double scale) {
    processNoiseScale = scale.clamp(0.1, 2.0);
  }

  /// Update with Deep Learning forward velocity estimate (VelocityCNN / Ensemble).
  /// Routes measurement through the ESKF Kalman update so covariance P is reduced.
  void updateMlVelocity(double vMl, double rMl) {
    if (vMl < 0) return;

    final yaw = q.toEuler().x;
    // Linearized forward velocity: v_forward = v_x * cos(yaw) + v_y * sin(yaw)
    final hForward = List<double>.filled(15, 0.0)
      ..[3] = cos(yaw)
      ..[4] = sin(yaw);

    final currentForward = v.x * cos(yaw) + v.y * sin(yaw);
    final innov = vMl - currentForward;
    final rVariance = max(rMl, 0.15); // Protect against degenerate variance

    _updateScalarMeasurement(
      hRow: hForward,
      innovation: innov,
      rVariance: rVariance,
    );

    // Maintain forwardSpeed tracking
    final newForward = v.x * cos(yaw) + v.y * sin(yaw);
    forwardSpeed = max(0.0, newForward);
  }

  /// Non-Holonomic Constraints (NHC):
  /// Lateral velocity in vehicle body frame ~ 0: -v_x * sin(yaw) + v_y * cos(yaw) = 0.
  /// Vertical velocity in vehicle body frame ~ 0: v_z = 0.
  /// Configurable noise variances support two-wheeler banking vs passenger car rigidity.
  void updateNhc({double lateralStd = 0.05, double verticalStd = 0.05}) {
    final yaw = q.toEuler().x;
    final rLat = max(lateralStd * lateralStd, 0.0001);
    final rDown = max(verticalStd * verticalStd, 0.0001);

    // 1. Lateral body velocity constraint
    final hLat = List<double>.filled(15, 0.0)
      ..[3] = -sin(yaw)
      ..[4] = cos(yaw);
    final currentLat = -v.x * sin(yaw) + v.y * cos(yaw);
    _updateScalarMeasurement(
      hRow: hLat,
      innovation: 0.0 - currentLat,
      rVariance: rLat,
    );

    // 2. Down/vertical velocity constraint
    final hDown = List<double>.filled(15, 0.0)..[5] = 1.0;
    _updateScalarMeasurement(
      hRow: hDown,
      innovation: 0.0 - v.z,
      rVariance: rDown,
    );

    // Enforce 2D vehicle planar state
    v = Vector3(v.x, v.y, 0.0);
    forwardSpeed = sqrt(v.x * v.x + v.y * v.y);
  }

  /// Zero Velocity Update (ZUPT): When stationary, vehicle speed is locked to zero.
  /// Routes through Kalman updates to reduce velocity covariance and eliminate drift.
  void updateZupt() {
    const rZupt = 0.001; // High confidence zero velocity

    // Update vx
    final hVx = List<double>.filled(15, 0.0)..[3] = 1.0;
    _updateScalarMeasurement(hRow: hVx, innovation: 0.0 - v.x, rVariance: rZupt);

    // Update vy
    final hVy = List<double>.filled(15, 0.0)..[4] = 1.0;
    _updateScalarMeasurement(hRow: hVy, innovation: 0.0 - v.y, rVariance: rZupt);

    // Update vz
    final hVz = List<double>.filled(15, 0.0)..[5] = 1.0;
    _updateScalarMeasurement(hRow: hVz, innovation: 0.0 - v.z, rVariance: rZupt);

    forwardSpeed = 0.0;
    v = Vector3.zero;
  }

  /// GNSS position and velocity update.
  /// Anchors local position, resets accumulated drift cleanly,
  /// and updates ESKF state + covariance via Kalman updates.
  void updateGnss(
    double lat,
    double lon,
    double accuracy, {
    double? speed,
    double? heading,
  }) {
    final ned = GeoUtils.latLonToNed(lat, lon, originLat, originLon);
    final errorDist = sqrt((ned.x - p.x) * (ned.x - p.x) + (ned.y - p.y) * (ned.y - p.y));

    final rPos = max(accuracy * accuracy, 1.0);

    if (errorDist > 30.0) {
      // Hard anchor on large gap
      p = Vector3(ned.x, ned.y, p.z);
      // Reset position covariance rows and columns
      for (int i = 0; i < 15; i++) {
        _setP(0, i, 0.0);
        _setP(i, 0, 0.0);
        _setP(1, i, 0.0);
        _setP(i, 1, 0.0);
      }
      _setP(0, 0, rPos);
      _setP(1, 1, rPos);
    } else {
      // North measurement: hRow[0] = 1.0
      final hNorth = List<double>.filled(15, 0.0)..[0] = 1.0;
      _updateScalarMeasurement(
        hRow: hNorth,
        innovation: ned.x - p.x,
        rVariance: rPos,
      );

      // East measurement: hRow[1] = 1.0
      final hEast = List<double>.filled(15, 0.0)..[1] = 1.0;
      _updateScalarMeasurement(
        hRow: hEast,
        innovation: ned.y - p.y,
        rVariance: rPos,
      );
    }

    // Velocity update from GNSS course-over-ground
    if (speed != null && speed >= 0.5 && heading != null) {
      final headingRad = heading * pi / 180.0;
      final vnGnss = speed * cos(headingRad);
      final veGnss = speed * sin(headingRad);
      const rVel = 0.25; // ~0.5 m/s 1-sigma

      final hVelN = List<double>.filled(15, 0.0)..[3] = 1.0;
      _updateScalarMeasurement(
        hRow: hVelN,
        innovation: vnGnss - v.x,
        rVariance: rVel,
      );

      final hVelE = List<double>.filled(15, 0.0)..[4] = 1.0;
      _updateScalarMeasurement(
        hRow: hVelE,
        innovation: veGnss - v.y,
        rVariance: rVel,
      );

      forwardSpeed = speed;
    } else if (speed != null && speed >= 0.5) {
      // Speed only (no heading): scalar forward speed update along current yaw
      final yaw = q.toEuler().x;
      final hSpeed = List<double>.filled(15, 0.0)
        ..[3] = cos(yaw)
        ..[4] = sin(yaw);
      final currentForward = v.x * cos(yaw) + v.y * sin(yaw);
      _updateScalarMeasurement(
        hRow: hSpeed,
        innovation: speed - currentForward,
        rVariance: 0.36,
      );
      forwardSpeed = speed;
    }

    // Align yaw with GNSS course over ground when vehicle is moving steadily
    if (heading != null && speed != null && speed > 2.5) {
      final currentYawDeg = headingDegrees;
      final diffDeg = GeoUtils.wrapDegrees(heading - currentYawDeg);
      if (diffDeg.abs() < 45.0) {
        final yawInnovRad = diffDeg * pi / 180.0;
        final hYaw = List<double>.filled(15, 0.0)..[8] = 1.0;
        const rYaw = (5.0 * pi / 180.0) * (5.0 * pi / 180.0);
        _updateScalarMeasurement(
          hRow: hYaw,
          innovation: yawInnovRad,
          rVariance: rYaw,
        );
      }
    }
  }

  void _symmetrizeP() {
    for (int i = 0; i < 15; i++) {
      for (int j = i + 1; j < 15; j++) {
        final avg = (_getP(i, j) + _getP(j, i)) * 0.5;
        _setP(i, j, avg);
        _setP(j, i, avg);
      }
      if (_getP(i, i) < 1e-8) {
        _setP(i, i, 1e-8);
      }
    }
  }

  void _updateScalarMeasurement({
    required List<double> hRow,
    required double innovation,
    required double rVariance,
  }) {
    // pht = P * H^T
    final pht = List<double>.filled(15, 0.0);
    double hpht = 0.0;
    for (int i = 0; i < 15; i++) {
      double sum = 0.0;
      for (int j = 0; j < 15; j++) {
        sum += _getP(i, j) * hRow[j];
      }
      pht[i] = sum;
      hpht += hRow[i] * sum;
    }

    final s = hpht + rVariance;
    if (s.abs() < 1e-12) return;
    final invS = 1.0 / s;

    final dx = List<double>.filled(15, 0.0);
    for (int i = 0; i < 15; i++) {
      dx[i] = pht[i] * invS * innovation;
    }

    _injectErrorState(dx);

    // Covariance update: P = P - K * (H * P) = P - (P * H^T) * (P * H^T)^T / S
    for (int i = 0; i < 15; i++) {
      for (int j = 0; j < 15; j++) {
        _setP(i, j, _getP(i, j) - pht[i] * pht[j] * invS);
      }
    }
    _symmetrizeP();
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
