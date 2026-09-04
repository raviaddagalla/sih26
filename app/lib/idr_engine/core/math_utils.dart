import 'dart:math';

/// 3D Vector with standard linear algebra operations.
class Vector3 {
  final double x;
  final double y;
  final double z;

  const Vector3(this.x, this.y, this.z);

  static const zero = Vector3(0.0, 0.0, 0.0);

  Vector3 operator +(Vector3 o) => Vector3(x + o.x, y + o.y, z + o.z);
  Vector3 operator -(Vector3 o) => Vector3(x - o.x, y - o.y, z - o.z);
  Vector3 operator *(double s) => Vector3(x * s, y * s, z * s);
  Vector3 operator -() => Vector3(-x, -y, -z);

  double dot(Vector3 o) => x * o.x + y * o.y + z * o.z;

  Vector3 cross(Vector3 o) => Vector3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  double get norm => sqrt(x * x + y * y + z * z);
  double get normSquared => x * x + y * y + z * z;

  Vector3 normalized() {
    final n = norm;
    if (n < 1e-12) return zero;
    return Vector3(x / n, y / n, z / n);
  }

  Matrix3 skewSymmetric() {
    return Matrix3([
      0.0, -z, y,
      z, 0.0, -x,
      -y, x, 0.0,
    ]);
  }

  List<double> toList() => [x, y, z];

  @override
  String toString() => '[${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)}]';
}

/// 3x3 Matrix stored row-major.
class Matrix3 {
  final List<double> m; // 9 elements

  Matrix3(this.m) {
    assert(m.length == 9);
  }

  static Matrix3 identity() => Matrix3([
        1.0, 0.0, 0.0,
        0.0, 1.0, 0.0,
        0.0, 0.0, 1.0,
      ]);

  static Matrix3 zero() => Matrix3(List.filled(9, 0.0));

  static Matrix3 diag(double d0, double d1, double d2) => Matrix3([
        d0, 0.0, 0.0,
        0.0, d1, 0.0,
        0.0, 0.0, d2,
      ]);

  double get(int row, int col) => m[row * 3 + col];
  void set(int row, int col, double val) {
    m[row * 3 + col] = val;
  }

  Matrix3 operator +(Matrix3 o) {
    final res = List<double>.filled(9, 0.0);
    for (int i = 0; i < 9; i++) {
      res[i] = m[i] + o.m[i];
    }
    return Matrix3(res);
  }

  Matrix3 operator -(Matrix3 o) {
    final res = List<double>.filled(9, 0.0);
    for (int i = 0; i < 9; i++) {
      res[i] = m[i] - o.m[i];
    }
    return Matrix3(res);
  }

  Matrix3 operator *(double s) {
    final res = List<double>.filled(9, 0.0);
    for (int i = 0; i < 9; i++) {
      res[i] = m[i] * s;
    }
    return Matrix3(res);
  }

  Vector3 multiplyVector(Vector3 v) {
    return Vector3(
      m[0] * v.x + m[1] * v.y + m[2] * v.z,
      m[3] * v.x + m[4] * v.y + m[5] * v.z,
      m[6] * v.x + m[7] * v.y + m[8] * v.z,
    );
  }

  Matrix3 multiply(Matrix3 o) {
    final res = List<double>.filled(9, 0.0);
    for (int r = 0; r < 3; r++) {
      for (int c = 0; c < 3; c++) {
        res[r * 3 + c] = m[r * 3 + 0] * o.m[0 * 3 + c] +
            m[r * 3 + 1] * o.m[1 * 3 + c] +
            m[r * 3 + 2] * o.m[2 * 3 + c];
      }
    }
    return Matrix3(res);
  }

  Matrix3 transpose() => Matrix3([
        m[0], m[3], m[6],
        m[1], m[4], m[7],
        m[2], m[5], m[8],
      ]);

  Matrix3 inverse() {
    final det = m[0] * (m[4] * m[8] - m[5] * m[7]) -
        m[1] * (m[3] * m[8] - m[5] * m[6]) +
        m[2] * (m[3] * m[7] - m[4] * m[6]);
    if (det.abs() < 1e-15) return Matrix3.identity();
    final invDet = 1.0 / det;

    return Matrix3([
      (m[4] * m[8] - m[5] * m[7]) * invDet,
      (m[2] * m[7] - m[1] * m[8]) * invDet,
      (m[1] * m[5] - m[2] * m[4]) * invDet,
      (m[5] * m[6] - m[3] * m[8]) * invDet,
      (m[0] * m[8] - m[2] * m[6]) * invDet,
      (m[2] * m[3] - m[0] * m[5]) * invDet,
      (m[3] * m[7] - m[4] * m[6]) * invDet,
      (m[1] * m[6] - m[0] * m[7]) * invDet,
      (m[0] * m[4] - m[1] * m[3]) * invDet,
    ]);
  }
}

/// Quaternion representation [x, y, z, w].
class Quaternion {
  final double x;
  final double y;
  final double z;
  final double w;

  const Quaternion(this.x, this.y, this.z, this.w);

  static const identity = Quaternion(0.0, 0.0, 0.0, 1.0);

  static Quaternion fromRotationVector(Vector3 rotVec) {
    final angle = rotVec.norm;
    if (angle < 1e-8) {
      return Quaternion(
        0.5 * rotVec.x,
        0.5 * rotVec.y,
        0.5 * rotVec.z,
        1.0,
      ).normalized();
    }
    final halfAngle = angle * 0.5;
    final sinHalf = sin(halfAngle) / angle;
    return Quaternion(
      rotVec.x * sinHalf,
      rotVec.y * sinHalf,
      rotVec.z * sinHalf,
      cos(halfAngle),
    ).normalized();
  }

  static Quaternion fromEuler(double yaw, double pitch, double roll) {
    // ZYX Euler sequence (yaw around Z, pitch around Y, roll around X)
    final cy = cos(yaw * 0.5);
    final sy = sin(yaw * 0.5);
    final cp = cos(pitch * 0.5);
    final sp = sin(pitch * 0.5);
    final cr = cos(roll * 0.5);
    final sr = sin(roll * 0.5);

    return Quaternion(
      sr * cp * cy - cr * sp * sy,
      cr * sp * cy + sr * cp * sy,
      cr * cp * sy - sr * sp * cy,
      cr * cp * cy + sr * sp * sy,
    ).normalized();
  }

  Quaternion multiply(Quaternion o) {
    return Quaternion(
      w * o.x + x * o.w + y * o.z - z * o.y,
      w * o.y - x * o.z + y * o.w + z * o.x,
      w * o.z + x * o.y - y * o.x + z * o.w,
      w * o.w - x * o.x - y * o.y - z * o.z,
    ).normalized();
  }

  Quaternion normalized() {
    final n = sqrt(x * x + y * y + z * z + w * w);
    if (n < 1e-12) return identity;
    return Quaternion(x / n, y / n, z / n, w / n);
  }

  /// Converts quaternion to 3x3 rotation matrix (Body to Navigation frame C_bn).
  Matrix3 toRotationMatrix() {
    final xx = x * x;
    final yy = y * y;
    final zz = z * z;
    final xy = x * y;
    final xz = x * z;
    final yz = y * z;
    final wx = w * x;
    final wy = w * y;
    final wz = w * z;

    return Matrix3([
      1.0 - 2.0 * (yy + zz), 2.0 * (xy - wz), 2.0 * (xz + wy),
      2.0 * (xy + wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz - wx),
      2.0 * (xz - wy), 2.0 * (yz + wx), 1.0 - 2.0 * (xx + yy),
    ]);
  }

  /// Extract Euler angles in radians [yaw, pitch, roll].
  Vector3 toEuler() {
    final sinrCosp = 2.0 * (w * x + y * z);
    final cosrCosp = 1.0 - 2.0 * (x * x + y * y);
    final roll = atan2(sinrCosp, cosrCosp);

    final sinp = 2.0 * (w * y - z * x);
    final double pitch;
    if (sinp.abs() >= 1.0) {
      pitch = (sinp > 0 ? 1 : -1) * pi / 2.0;
    } else {
      pitch = asin(sinp);
    }

    final sinyCosp = 2.0 * (w * z + x * y);
    final cosyCosp = 1.0 - 2.0 * (y * y + z * z);
    final yaw = atan2(sinyCosp, cosyCosp);

    return Vector3(yaw, pitch, roll);
  }
}

/// WGS84 Geodetic coordinate conversions.
class GeoUtils {
  static const double earthRadius = 6378137.0; // WGS84 semi-major axis (meters)

  static double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  /// Converts latitude/longitude to local NED meters relative to origin.
  /// North = x, East = y.
  static Vector3 latLonToNed(double lat, double lon, double originLat, double originLon) {
    final latRad = originLat * pi / 180.0;
    final dLatRad = (lat - originLat) * pi / 180.0;
    final dLonRad = (lon - originLon) * pi / 180.0;

    final north = dLatRad * earthRadius;
    final east = dLonRad * earthRadius * cos(latRad);
    return Vector3(north, east, 0.0);
  }

  /// Converts local NED meters back to latitude/longitude.
  static (double lat, double lon) nedToLatLon(double north, double east, double originLat, double originLon) {
    final latRad = originLat * pi / 180.0;
    final dLat = (north / earthRadius) * 180.0 / pi;
    final dLon = (east / (earthRadius * cos(latRad))) * 180.0 / pi;
    return (originLat + dLat, originLon + dLon);
  }

  /// Wrap angle to [-180, 180] degrees.
  static double wrapDegrees(double deg) {
    double wrapped = (deg + 180.0) % 360.0;
    if (wrapped < 0) wrapped += 360.0;
    return wrapped - 180.0;
  }

  /// Wrap angle to [-pi, pi] radians.
  static double wrapRadians(double rad) {
    double wrapped = (rad + pi) % (2.0 * pi);
    if (wrapped < 0) wrapped += 2.0 * pi;
    return wrapped - pi;
  }
}
