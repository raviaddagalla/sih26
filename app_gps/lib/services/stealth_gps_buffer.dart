import 'dart:math';

class TimedGpsFix {
  final DateTime time;
  final double latitude;
  final double longitude;
  final double speed;
  final double heading;
  final double accuracy;

  const TimedGpsFix({
    required this.time,
    required this.latitude,
    required this.longitude,
    required this.speed,
    required this.heading,
    required this.accuracy,
  });
}

/// Buffers live GPS fixes and produces ultra-smooth interpolated positions
/// with an adjustable lag behind real time.
class StealthGpsBuffer {
  final List<TimedGpsFix> _fixes = [];

  void addFix({
    required double latitude,
    required double longitude,
    required double speed,
    required double heading,
    required double accuracy,
    DateTime? timestamp,
  }) {
    final now = timestamp ?? DateTime.now();
    _fixes.add(TimedGpsFix(
      time: now,
      latitude: latitude,
      longitude: longitude,
      speed: speed,
      heading: heading,
      accuracy: accuracy,
    ));

    // Prune fixes older than 15 seconds
    final cutoff = now.subtract(const Duration(seconds: 15));
    _fixes.removeWhere((f) => f.time.isBefore(cutoff));
  }

  void clear() {
    _fixes.clear();
  }

  bool get isEmpty => _fixes.isEmpty;

  TimedGpsFix? get latest => _fixes.isNotEmpty ? _fixes.last : null;

  /// Retrieves the position at (now - lagSeconds).
  /// Linearly interpolates lat, lon, speed, and heading between recorded GPS epochs.
  TimedGpsFix? getLaggedFix(double lagSeconds) {
    if (_fixes.isEmpty) return null;
    if (lagSeconds <= 0.005 || _fixes.length == 1) {
      return _fixes.last;
    }

    final now = DateTime.now();
    final targetTime = now.subtract(Duration(milliseconds: (lagSeconds * 1000).round()));

    if (targetTime.isBefore(_fixes.first.time)) {
      return _fixes.first;
    }
    if (targetTime.isAfter(_fixes.last.time)) {
      return _fixes.last;
    }

    for (int i = 0; i < _fixes.length - 1; i++) {
      final a = _fixes[i];
      final b = _fixes[i + 1];
      if ((a.time.isBefore(targetTime) || a.time.isAtSameMomentAs(targetTime)) &&
          (b.time.isAfter(targetTime) || b.time.isAtSameMomentAs(targetTime))) {
        final totalMs = b.time.difference(a.time).inMilliseconds;
        if (totalMs <= 0) return a;
        final elapsedMs = targetTime.difference(a.time).inMilliseconds;
        final t = (elapsedMs / totalMs).clamp(0.0, 1.0);

        final lat = a.latitude + (b.latitude - a.latitude) * t;
        final lon = a.longitude + (b.longitude - a.longitude) * t;
        final speed = a.speed + (b.speed - a.speed) * t;

        // Shortest-path heading interpolation
        final hDiff = ((b.heading - a.heading + 540) % 360) - 180;
        final heading = (a.heading + hDiff * t) % 360;

        return TimedGpsFix(
          time: targetTime,
          latitude: lat,
          longitude: lon,
          speed: speed,
          heading: heading < 0 ? heading + 360 : heading,
          accuracy: a.accuracy + (b.accuracy - a.accuracy) * t,
        );
      }
    }

    return _fixes.last;
  }
}
