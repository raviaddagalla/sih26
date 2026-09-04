/// Generic IMU Sample representation.
/// Decouples the IDR Engine from smartphone or external IMU hardware.
class ImuSample {
  final double timestamp; // seconds or fractional seconds
  final double ax; // m/s^2 forward/X
  final double ay; // m/s^2 lateral/Y
  final double az; // m/s^2 vertical/Z
  final double gx; // rad/s roll rate
  final double gy; // rad/s pitch rate
  final double gz; // rad/s yaw rate
  final double? mx; // microTesla (optional magnetometer)
  final double? my;
  final double? mz;

  const ImuSample({
    required this.timestamp,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    this.mx,
    this.my,
    this.mz,
  });

  List<double> toList6() => [ax, ay, az, gx, gy, gz];

  @override
  String toString() =>
      'ImuSample(t: ${timestamp.toStringAsFixed(3)}, a: [${ax.toStringAsFixed(2)}, ${ay.toStringAsFixed(2)}, ${az.toStringAsFixed(2)}], g: [${gx.toStringAsFixed(3)}, ${gy.toStringAsFixed(3)}, ${gz.toStringAsFixed(3)}])';
}
