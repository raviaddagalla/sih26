import 'dart:math';
import '../core/gnss_sample.dart';

enum GnssIntegrityStatus {
  healthy,
  suspectedSpoofing,
  suspectedJamming,
  structuralOutage,
}

/// Advanced GNSS Integrity and Anti-Spoofing / Anti-Jamming Monitor.
/// Fulfills the explicit SIH requirement regarding electromagnetic interference and signal corruption.
/// Protects the ESKF by gating kinematically implausible satellite fixes.
class GnssIntegrityMonitor {
  GnssIntegrityStatus _status = GnssIntegrityStatus.healthy;
  GnssIntegrityStatus get status => _status;

  String _lastWarningMessage = '';
  String get lastWarningMessage => _lastWarningMessage;

  int _divergenceConsecutiveTicks = 0;
  double _lastValidLat = 0.0;
  double _lastValidLon = 0.0;
  double _lastValidTimestamp = 0.0;

  void reset() {
    _status = GnssIntegrityStatus.healthy;
    _lastWarningMessage = '';
    _divergenceConsecutiveTicks = 0;
    _lastValidLat = 0.0;
    _lastValidLon = 0.0;
    _lastValidTimestamp = 0.0;
  }

  /// Evaluates incoming GNSS fix against IMU-predicted kinematic state.
  /// Returns [true] if fix should be accepted into the ESKF, or [false] if rejected.
  bool evaluateFix({
    required GnssSample gnss,
    required double imuSpeedMps,
    required double imuHeadingDeg,
    required bool isStationaryZupt,
    required bool isNearKnownDenialZone,
  }) {
    if (!gnss.isAvailable || gnss.latitude == 0.0) {
      _status = isNearKnownDenialZone
          ? GnssIntegrityStatus.structuralOutage
          : GnssIntegrityStatus.healthy;
      return false;
    }

    if (_lastValidTimestamp == 0.0) {
      _lastValidLat = gnss.latitude;
      _lastValidLon = gnss.longitude;
      _lastValidTimestamp = gnss.timestamp;
      _status = GnssIntegrityStatus.healthy;
      return true;
    }

    final dt = max(0.01, gnss.timestamp - _lastValidTimestamp);
    final distanceM = _haversineMeters(_lastValidLat, _lastValidLon, gnss.latitude, gnss.longitude);

    // 1. Check: Stationary False Velocity (Ghost Movement / Spoofing)
    if (isStationaryZupt && gnss.speed > 5.0) {
      _divergenceConsecutiveTicks++;
      _status = GnssIntegrityStatus.suspectedSpoofing;
      _lastWarningMessage =
          'GNSS Spoofing Alert: Satellite claims ${(gnss.speed * 3.6).toInt()} km/h while vehicle IMU is completely stationary!';
      return false;
    }

    // 2. Check: Teleportation / Kinematically Impossible Jump
    final maxPlausibleDistance = (imuSpeedMps * dt) + (3.0 * gnss.accuracy) + 15.0;
    if (distanceM > maxPlausibleDistance && distanceM > 35.0) {
      _divergenceConsecutiveTicks++;
      _status = GnssIntegrityStatus.suspectedJamming;
      _lastWarningMessage =
          'Kinematic Innovation Jump: ${distanceM.toInt()}m shift in ${dt.toStringAsFixed(1)}s exceeds physical vehicular acceleration limits.';
      return false; // Reject spoofed coordinate
    }

    // 3. Check: Heading Inversion Divergence (> 120° deviation at highway speed)
    if (imuSpeedMps > 8.0 && gnss.speed > 8.0) {
      final headingDiff = ((gnss.heading - imuHeadingDeg + 540) % 360) - 180;
      if (headingDiff.abs() > 110.0) {
        _divergenceConsecutiveTicks++;
        if (_divergenceConsecutiveTicks >= 4) {
          _status = GnssIntegrityStatus.suspectedJamming;
          _lastWarningMessage =
              'Severe Course Inversion: GNSS heading deviates ${headingDiff.abs().toInt()}° from vehicle inertial vector.';
          return false;
        }
      }
    }

    // 4. Check: Sudden Accuracy Collapse without Structural Masking
    if (gnss.accuracy > 80.0 && !isNearKnownDenialZone) {
      _status = GnssIntegrityStatus.suspectedJamming;
      _lastWarningMessage =
          'GNSS Interference Detected: Satellite accuracy degraded to ${gnss.accuracy.toInt()}m in open sky.';
      // Down-weighted fix allowed with high R variance
      _lastValidLat = gnss.latitude;
      _lastValidLon = gnss.longitude;
      _lastValidTimestamp = gnss.timestamp;
      return true;
    }

    // All integrity checks passed
    _divergenceConsecutiveTicks = 0;
    _status = GnssIntegrityStatus.healthy;
    _lastValidLat = gnss.latitude;
    _lastValidLon = gnss.longitude;
    _lastValidTimestamp = gnss.timestamp;
    return true;
  }

  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const R = 6378137.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
