import 'package:flutter/foundation.dart';

@immutable
class NavigationSnapshot {
  const NavigationSnapshot({
    required this.mode,
    required this.speedKmh,
    required this.heading,
    required this.distanceKm,
    required this.signalLabel,
    required this.accuracyMeters,
    required this.updatedAt,
    required this.latitude,
    required this.longitude,
    required this.gpsAvailable,
    required this.demoMode,
    this.activeRoute,
  });

  final NavigationMode mode;
  final double speedKmh;
  final double heading;
  final double distanceKm;
  final String signalLabel;
  final double accuracyMeters;
  final DateTime updatedAt;
  final double latitude;
  final double longitude;
  final bool gpsAvailable;
  final bool demoMode;
  final List<dynamic>? activeRoute;
}

enum NavigationMode { gnss, deadReckoning }

class SensorSample {
  const SensorSample({
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.timestamp,
  });

  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final DateTime timestamp;
}

class PositionPoint {
  const PositionPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}
