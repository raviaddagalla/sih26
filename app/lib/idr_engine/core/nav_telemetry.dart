enum NavMode {
  gnssIns,
  deadReckoning,
  gnssRecovery,
}

enum GnssQuality {
  strong,
  degraded,
  denied,
  reacquiring,
}

/// Real-time navigation telemetry produced at 10 Hz by the IDR engine.
class NavigationTelemetry {
  final double timestamp;
  final double latitude;
  final double longitude;
  final double? altitude;
  final double velocity; // m/s
  final double aiVelocity; // m/s from VelocityCNN
  final double gnssVelocity; // m/s from GNSS
  final double heading; // degrees
  final NavMode navMode;
  final GnssQuality gnssQuality;
  final double imuSamplingRate; // Hz
  final double positionUncertainty; // meters
  final double totalDistance; // meters
  final double driftPercentage; // %
  final bool isStationary; // ZUPT state
  final bool isDemoMode;
  final double? groundTruthLat;
  final double? groundTruthLon;
  final double? groundTruthSpeed;
  final double? remainingDistanceMeters;
  final List<dynamic>? slicedRoutePoints;
  final bool isOffRoute;
  final int currentSegmentIndex;

  const NavigationTelemetry({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    this.altitude,
    required this.velocity,
    required this.aiVelocity,
    required this.gnssVelocity,
    required this.heading,
    required this.navMode,
    required this.gnssQuality,
    required this.imuSamplingRate,
    required this.positionUncertainty,
    required this.totalDistance,
    required this.driftPercentage,
    required this.isStationary,
    this.isDemoMode = false,
    this.groundTruthLat,
    this.groundTruthLon,
    this.groundTruthSpeed,
    this.remainingDistanceMeters,
    this.slicedRoutePoints,
    this.isOffRoute = false,
    this.currentSegmentIndex = 0,
  });

  double get speedKmh => velocity * 3.6;

  String get navModeString {
    switch (navMode) {
      case NavMode.gnssIns:
        return 'GNSS + INS';
      case NavMode.deadReckoning:
        return 'DEAD RECKONING';
      case NavMode.gnssRecovery:
        return 'GNSS RECOVERY';
    }
  }

  String get gnssQualityString {
    switch (gnssQuality) {
      case GnssQuality.strong:
        return 'STRONG';
      case GnssQuality.degraded:
        return 'DEGRADED';
      case GnssQuality.denied:
        return 'DENIED';
      case GnssQuality.reacquiring:
        return 'REACQUIRING';
    }
  }
}
