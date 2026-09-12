import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:navigate_phase1/idr_engine/calibration/phone_alignment.dart';
import 'package:navigate_phase1/idr_engine/core/imu_sample.dart';
import 'package:navigate_phase1/idr_engine/core/math_utils.dart';
import 'package:navigate_phase1/idr_engine/eskf/eskf.dart';

void main() {
  group('PhoneAlignment & Rotational Sense Verification', () {
    test('Stationary flat phone (0, 0, 9.81) calibrates gravity alignment correctly', () {
      final alignment = PhoneAlignment();
      expect(alignment.isGravityCalibrated, isFalse);

      // Feed 50 stationary samples of flat phone (screen up, normal force ~ +9.81 m/s^2 along +Z)
      for (int i = 0; i < 50; i++) {
        alignment.addStationarySample(const Vector3(0.0, 0.0, 9.81));
      }

      expect(alignment.isGravityCalibrated, isTrue);

      // Verify transformed stationary accelerometer points in -Z (or vehicle gravity vector ~ [0, 0, -9.81])
      final sample = ImuSample(
        timestamp: 0.0,
        ax: 0.0,
        ay: 0.0,
        az: 9.81,
        gx: 0.0,
        gy: 0.0,
        gz: 0.0,
      );
      final transformed = alignment.transform(sample);

      // In NED frame, stationary specific force points UP (-Z in NED, so az is -9.81)
      expect(transformed.ax, closeTo(0.0, 1e-4));
      expect(transformed.ay, closeTo(0.0, 1e-4));
      expect(transformed.az, closeTo(-9.81, 1e-4));
    });

    test('Clockwise (right turn) rotation increases ESKF headingDegrees', () {
      final alignment = PhoneAlignment();
      for (int i = 0; i < 50; i++) {
        alignment.addStationarySample(const Vector3(0.0, 0.0, 9.81));
      }
      expect(alignment.isGravityCalibrated, isTrue);

      final eskf = ESKF(
        originLat: 13.0827,
        originLon: 80.2707,
        initHeadingRad: 0.0, // North = 0 deg
        initSpeed: 10.0,
      );

      final initialHeading = eskf.headingDegrees;
      expect(initialHeading, closeTo(0.0, 1e-3));

      // Android sensor convention: right-hand rule about +Z (out of screen).
      // Flat screen-up: right turn = clockwise rotation from above = NEGATIVE gz.
      // E.g. turning at ~0.5 rad/s (~28.6 deg/s) clockwise for 1.0s (100 steps @ 100Hz, dt = 0.01s).
      const turnRateRad = 0.5; // rad/s
      const dt = 0.01;

      for (int i = 0; i < 100; i++) {
        final rawSample = ImuSample(
          timestamp: i * dt,
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: -turnRateRad, // Android raw negative gz for clockwise / right turn
        );
        final vehSample = alignment.transform(rawSample);

        // Vehicle gyro Z should be positive (+0.5 rad/s in NED)
        expect(vehSample.gz, closeTo(turnRateRad, 1e-4));

        eskf.predict(
          dt,
          Vector3(vehSample.ax, vehSample.ay, vehSample.az),
          Vector3(vehSample.gx, vehSample.gy, vehSample.gz),
        );
      }

      final finalHeading = eskf.headingDegrees;
      // Heading should have increased clockwise by ~28.6 degrees
      final expectedHeadingDeg = turnRateRad * (180.0 / pi);
      expect(finalHeading, greaterThan(initialHeading));
      expect(finalHeading, closeTo(expectedHeadingDeg, 1.0));
    });

    test('Counter-clockwise (left turn) rotation decreases ESKF headingDegrees', () {
      final alignment = PhoneAlignment();
      for (int i = 0; i < 50; i++) {
        alignment.addStationarySample(const Vector3(0.0, 0.0, 9.81));
      }
      expect(alignment.isGravityCalibrated, isTrue);

      final eskf = ESKF(
        originLat: 13.0827,
        originLon: 80.2707,
        initHeadingRad: pi / 2.0, // East = 90 deg
        initSpeed: 10.0,
      );

      final initialHeading = eskf.headingDegrees;
      expect(initialHeading, closeTo(90.0, 1e-3));

      // Flat screen-up: left turn = counter-clockwise rotation = POSITIVE gz in Android.
      const turnRateRad = 0.5;
      const dt = 0.01;

      for (int i = 0; i < 100; i++) {
        final rawSample = ImuSample(
          timestamp: i * dt,
          ax: 0.0,
          ay: 0.0,
          az: 9.81,
          gx: 0.0,
          gy: 0.0,
          gz: turnRateRad, // Android raw positive gz for counter-clockwise / left turn
        );
        final vehSample = alignment.transform(rawSample);

        // Vehicle gyro Z should be negative (-0.5 rad/s in NED)
        expect(vehSample.gz, closeTo(-turnRateRad, 1e-4));

        eskf.predict(
          dt,
          Vector3(vehSample.ax, vehSample.ay, vehSample.az),
          Vector3(vehSample.gx, vehSample.gy, vehSample.gz),
        );
      }

      final finalHeading = eskf.headingDegrees;
      // Heading should have decreased counter-clockwise from 90 deg by ~28.6 degrees -> ~61.4 deg
      final expectedHeadingDeg = 90.0 - (turnRateRad * (180.0 / pi));
      expect(finalHeading, lessThan(initialHeading));
      expect(finalHeading, closeTo(expectedHeadingDeg, 1.0));
    });

    test('Portrait mounted phone aligns upright gravity and maintains turn direction', () {
      final alignment = PhoneAlignment();
      // In portrait holder: top of phone (+Y) points UP against gravity, so ay ~ +9.81
      for (int i = 0; i < 50; i++) {
        alignment.addStationarySample(const Vector3(0.0, 9.81, 0.0));
      }
      expect(alignment.isGravityCalibrated, isTrue);

      final eskf = ESKF(
        originLat: 13.0827,
        originLon: 80.2707,
        initHeadingRad: 0.0,
        initSpeed: 10.0,
      );

      // Rotating clockwise from above around vertical axis (which is phone +Y):
      // By right-hand rule about +Y, clockwise is NEGATIVE gy.
      const turnRateRad = 0.4;
      const dt = 0.01;

      for (int i = 0; i < 100; i++) {
        final rawSample = ImuSample(
          timestamp: i * dt,
          ax: 0.0,
          ay: 9.81,
          az: 0.0,
          gx: 0.0,
          gy: -turnRateRad, // Clockwise around vertical axis
          gz: 0.0,
        );
        final vehSample = alignment.transform(rawSample);

        // Transformed vehicle frame: yaw rate should be positive (+turnRateRad)
        expect(vehSample.gz, closeTo(turnRateRad, 1e-4));

        eskf.predict(
          dt,
          Vector3(vehSample.ax, vehSample.ay, vehSample.az),
          Vector3(vehSample.gx, vehSample.gy, vehSample.gz),
        );
      }

      // Heading should have increased clockwise
      expect(eskf.headingDegrees, greaterThan(0.0));
    });
  });
}
