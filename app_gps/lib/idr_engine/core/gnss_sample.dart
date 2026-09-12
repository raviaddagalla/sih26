/// Standardized GNSS Measurement.
/// Consumed by the IDR engine for measurement updates and outage tracking.
class GnssSample {
  final double timestamp; // seconds
  final double latitude; // decimal degrees
  final double longitude; // decimal degrees
  final double? altitude; // meters
  final double speed; // m/s
  final double accuracy; // meters (1-sigma horizontal accuracy)
  final double heading; // degrees (0-360)
  final bool isAvailable; // false during outage/tunnel

  const GnssSample({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    this.altitude,
    required this.speed,
    required this.accuracy,
    required this.heading,
    required this.isAvailable,
  });

  @override
  String toString() =>
      'GnssSample(t: ${timestamp.toStringAsFixed(2)}, pos: [$latitude, $longitude], spd: ${speed.toStringAsFixed(1)} m/s, acc: ${accuracy.toStringAsFixed(1)}m, avail: $isAvailable)';
}
