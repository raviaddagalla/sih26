import '../core/nav_telemetry.dart';
import '../core/gnss_sample.dart';

/// Explicit GNSS Quality and Outage Detection State Machine.
/// Prevents erratic position jumps by modulating measurement trust and
/// smoothly managing transitions between GNSS+INS, Dead Reckoning, and Reacquisition.
class GnssStateMachine {
  GnssQuality _quality = GnssQuality.strong;
  NavMode _navMode = NavMode.gnssIns;

  double _lastValidGnssTimestamp = -1.0;
  int _consecutiveValidUpdates = 0;
  int _consecutiveOutageTicks = 0;

  GnssQuality get quality => _quality;
  NavMode get navMode => _navMode;
  int get consecutiveOutageTicks => _consecutiveOutageTicks;

  /// Process incoming GNSS measurement.
  void updateWithGnss(GnssSample sample) {
    _lastValidGnssTimestamp = sample.timestamp;

    if (!sample.isAvailable || sample.accuracy > 40.0) {
      // Degraded or invalid
      _handleOutageOrDegraded(sample.accuracy);
      return;
    }

    _consecutiveOutageTicks = 0;

    if (_quality == GnssQuality.denied) {
      // Entering Reacquisition phase
      _quality = GnssQuality.reacquiring;
      _navMode = NavMode.gnssRecovery;
      _consecutiveValidUpdates = 1;
    } else if (_quality == GnssQuality.reacquiring) {
      _consecutiveValidUpdates++;
      if (_consecutiveValidUpdates >= 4) {
        // Fully recovered back to STRONG or DEGRADED
        if (sample.accuracy <= 6.0) {
          _quality = GnssQuality.strong;
          _navMode = NavMode.gnssIns;
        } else {
          _quality = GnssQuality.degraded;
          _navMode = NavMode.gnssIns;
        }
      }
    } else {
      // Normal operating mode
      if (sample.accuracy <= 6.0) {
        _quality = GnssQuality.strong;
        _navMode = NavMode.gnssIns;
      } else {
        _quality = GnssQuality.degraded;
        _navMode = NavMode.gnssIns;
      }
    }
  }

  /// Periodic tick (e.g. at 10 Hz navigation rate) checking for silent signal loss.
  void checkTimeout(double currentTimestamp) {
    if (_lastValidGnssTimestamp < 0) return;

    final timeSinceLastGnss = currentTimestamp - _lastValidGnssTimestamp;
    if (timeSinceLastGnss > 2.5) {
      _consecutiveOutageTicks++;
      _consecutiveValidUpdates = 0;
      _quality = GnssQuality.denied;
      _navMode = NavMode.deadReckoning;
    }
  }

  void _handleOutageOrDegraded(double accuracy) {
    _consecutiveValidUpdates = 0;
    if (accuracy > 70.0) {
      _quality = GnssQuality.denied;
      _navMode = NavMode.deadReckoning;
    } else {
      _quality = GnssQuality.degraded;
      _navMode = NavMode.gnssIns;
    }
  }

  void reset() {
    _quality = GnssQuality.strong;
    _navMode = NavMode.gnssIns;
    _lastValidGnssTimestamp = -1.0;
    _consecutiveValidUpdates = 0;
    _consecutiveOutageTicks = 0;
  }
}
