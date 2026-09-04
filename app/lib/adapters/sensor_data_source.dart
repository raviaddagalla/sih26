import 'dart:async';
import '../idr_engine/core/imu_sample.dart';
import '../idr_engine/core/gnss_sample.dart';

/// Generic Sensor Data Source abstraction.
/// Enables the IDR Engine to operate identically whether connected to
/// live smartphone sensors, simulated test dataset replay, or an external automotive IMU.
abstract class SensorDataSource {
  Stream<ImuSample> get imuStream;
  Stream<GnssSample> get gnssStream;

  bool get isRunning;
  bool get isPaused;
  String get sourceName;

  Future<void> start();
  Future<void> stop();
  void pause();
  void resume();

  void dispose();
}
