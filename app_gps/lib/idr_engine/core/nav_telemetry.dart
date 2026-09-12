import 'package:latlong2/latlong.dart';
import '../denial_map/gnss_denial_map_service.dart';
import '../fusion/vehicle_profile.dart';
import '../fusion/gnss_integrity_monitor.dart';

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
  final List<LatLng>? slicedRoutePoints;
  final bool isOffRoute;
  final int currentSegmentIndex;
  final bool isGravityCalibrated;
  final bool isYawCalibrated;
  final bool isFullyCalibrated;
  final int calibrationProgressPercent;
  final bool isGnssForceBlocked;

  // Tier 1 & Tier 2 Differentiators
  final String activeEnsembleRegime;
  final DenialZoneAlert? denialZoneAlert;
  final VehicleType vehicleType;
  final GnssIntegrityStatus gnssIntegrity;
  final double onlineCalibrationScale;
  final double onlineCalibrationBias;
  final bool isSevereDeceleration;
  final bool isWrongWayDriving;
  final bool isEmergencyMode;

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
    this.isGravityCalibrated = true,
    this.isYawCalibrated = true,
    this.isFullyCalibrated = true,
    this.calibrationProgressPercent = 100,
    this.isGnssForceBlocked = false,
    this.activeEnsembleRegime = 'GRU (<5 m/s)',
    this.denialZoneAlert,
    this.vehicleType = VehicleType.passengerCar,
    this.gnssIntegrity = GnssIntegrityStatus.healthy,
    this.onlineCalibrationScale = 1.0,
    this.onlineCalibrationBias = 0.0,
    this.isSevereDeceleration = false,
    this.isWrongWayDriving = false,
    this.isEmergencyMode = false,
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
