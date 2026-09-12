/// Specific vehicle dynamic profiles catering to diverse automotive classes.
/// Directly fulfills SIH problem statement requirement emphasizing two-wheelers.
enum VehicleType {
  twoWheeler,
  passengerCar,
  commercialTruck,
}

class VehicleProfile {
  final VehicleType type;
  final String name;
  final String description;

  /// Accelerometer variance threshold for zero-velocity detection.
  /// Two-wheelers have significantly higher idle engine vibration than cars.
  final double zuptAccelVarianceThreshold;

  /// Gyroscope angular rate threshold for zero-velocity detection (rad/s).
  final double zuptGyroThreshold;

  /// Measurement noise standard deviation for Non-Holonomic lateral constraint (m/s).
  /// Two-wheelers bank and lean into corners, making the lateral velocity constraint weaker.
  final double nhcLateralNoiseStd;

  /// Measurement noise standard deviation for Non-Holonomic vertical constraint (m/s).
  final double nhcVerticalNoiseStd;

  /// Maximum plausible turning rate (deg/s).
  final double maxTurnRateDegPerSec;

  const VehicleProfile({
    required this.type,
    required this.name,
    required this.description,
    required this.zuptAccelVarianceThreshold,
    required this.zuptGyroThreshold,
    required this.nhcLateralNoiseStd,
    required this.nhcVerticalNoiseStd,
    required this.maxTurnRateDegPerSec,
  });

  /// Factory profile for Two-Wheelers (Motorcycles & Scooters).
  /// Compensates for handlebar mount engine buzz and corner banking dynamics.
  factory VehicleProfile.twoWheeler() => const VehicleProfile(
        type: VehicleType.twoWheeler,
        name: 'Two-Wheeler (Motorcycle/Scooter)',
        description:
            'Optimized for handlebar mounts with engine vibration tolerance & banking NHC dynamics.',
        zuptAccelVarianceThreshold: 0.18,
        zuptGyroThreshold: 0.08,
        nhcLateralNoiseStd: 0.25,
        nhcVerticalNoiseStd: 0.15,
        maxTurnRateDegPerSec: 50.0,
      );

  /// Factory profile for standard Passenger Cars (Sedans, SUVs, Hatchbacks).
  factory VehicleProfile.passengerCar() => const VehicleProfile(
        type: VehicleType.passengerCar,
        name: 'Passenger Car',
        description:
            'Standard dashboard/windshield mount with strict no-sideslip Non-Holonomic Constraints.',
        zuptAccelVarianceThreshold: 0.05,
        zuptGyroThreshold: 0.04,
        nhcLateralNoiseStd: 0.05,
        nhcVerticalNoiseStd: 0.05,
        maxTurnRateDegPerSec: 30.0,
      );

  /// Factory profile for Commercial Trucks & Heavy Transport.
  factory VehicleProfile.commercialTruck() => const VehicleProfile(
        type: VehicleType.commercialTruck,
        name: 'Commercial Truck / Bus',
        description:
            'Heavy vehicular inertia profile with low yaw rate dynamics and stiff vertical damping.',
        zuptAccelVarianceThreshold: 0.035,
        zuptGyroThreshold: 0.03,
        nhcLateralNoiseStd: 0.03,
        nhcVerticalNoiseStd: 0.04,
        maxTurnRateDegPerSec: 18.0,
      );

  static VehicleProfile getProfile(VehicleType type) {
    switch (type) {
      case VehicleType.twoWheeler:
        return VehicleProfile.twoWheeler();
      case VehicleType.passengerCar:
        return VehicleProfile.passengerCar();
      case VehicleType.commercialTruck:
        return VehicleProfile.commercialTruck();
    }
  }
}
