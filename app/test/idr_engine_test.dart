import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navigate_phase1/idr_engine/core/math_utils.dart';
import 'package:navigate_phase1/idr_engine/core/gnss_sample.dart';
import 'package:navigate_phase1/idr_engine/core/nav_telemetry.dart';
import 'package:navigate_phase1/idr_engine/eskf/eskf.dart';
import 'package:navigate_phase1/idr_engine/fusion/gnss_state_machine.dart';
import 'package:navigate_phase1/idr_engine/map_matching/route_matcher.dart';
import 'package:navigate_phase1/adapters/dataset_replay_adapter.dart';

void main() {
  group('Math & Coordinate Conversions', () {
    test('WGS84 Lat/Lon to NED and back round-trip consistency', () {
      const originLat = 24.363;
      const originLon = 88.628;

      // 500m North, 300m East
      const testLat = 24.3675;
      const testLon = 88.6310;

      final ned = GeoUtils.latLonToNed(testLat, testLon, originLat, originLon);
      expect(ned.x, greaterThan(0)); // North
      expect(ned.y, greaterThan(0)); // East

      final (recoveredLat, recoveredLon) = GeoUtils.nedToLatLon(ned.x, ned.y, originLat, originLon);
      expect(recoveredLat, closeTo(testLat, 1e-6));
      expect(recoveredLon, closeTo(testLon, 1e-6));
    });

    test('Quaternion rotation vector and rotation matrix', () {
      // 90 degrees around Z axis (Yaw)
      final rotVec = const Vector3(0.0, 0.0, pi / 2.0);
      final q = Quaternion.fromRotationVector(rotVec);
      final euler = q.toEuler();

      expect(euler.x, closeTo(pi / 2.0, 1e-3)); // Yaw ~ pi/2
      expect(euler.y, closeTo(0.0, 1e-3)); // Pitch ~ 0
      expect(euler.z, closeTo(0.0, 1e-3)); // Roll ~ 0

      final rotMatrix = q.toRotationMatrix();
      // Rotating [1, 0, 0] by 90 deg around Z gives [0, 1, 0]
      final vRot = rotMatrix.multiplyVector(const Vector3(1.0, 0.0, 0.0));
      expect(vRot.x, closeTo(0.0, 1e-4));
      expect(vRot.y, closeTo(1.0, 1e-4));
      expect(vRot.z, closeTo(0.0, 1e-4));
    });
  });

  group('ESKF 15-State Filter', () {
    test('Propagation maintains physical stability with no NaNs', () {
      final eskf = ESKF(
        originLat: 24.363,
        originLon: 88.628,
        initHeadingRad: 0.0,
        initSpeed: 10.0, // 10 m/s forward
      );

      // Propagate 100 IMU steps at 100 Hz (dt = 0.01s = 1.0s)
      for (int i = 0; i < 100; i++) {
        eskf.predict(
          0.01,
          const Vector3(0.0, 0.0, -9.81), // Compensates gravity in NED
          const Vector3(0.0, 0.0, 0.0), // Zero gyro rate
        );
      }

      expect(eskf.p.x.isNaN, isFalse);
      expect(eskf.v.x.isNaN, isFalse);
      expect(eskf.speed, closeTo(10.0, 0.5));
      expect(eskf.p.x, closeTo(10.0, 1.0)); // Travelled ~10m North
    });

    test('ML Forward Velocity and NHC updates constrain state', () {
      final eskf = ESKF(
        originLat: 24.363,
        originLon: 88.628,
        initHeadingRad: 0.0,
        initSpeed: 0.0,
      );

      // Inject AI forward velocity measurement: 12.5 m/s
      eskf.updateMlVelocity(12.5, 0.25);
      expect(eskf.v.x, closeTo(12.5, 2.0));

      // Non-holonomic constraints (lateral/vertical velocity ~ 0)
      eskf.updateNhc();
      expect(eskf.v.y, closeTo(0.0, 0.5));
      expect(eskf.v.z, closeTo(0.0, 0.5));
    });

    test('GNSS position update corrects position and uncertainty', () {
      final eskf = ESKF(
        originLat: 24.363,
        originLon: 88.628,
        initHeadingRad: 0.0,
        initSpeed: 0.0,
      );

      final initialUncertainty = eskf.positionUncertainty;

      // GNSS fix at origin with high accuracy (2m)
      eskf.updateGnss(24.3630, 88.6280, 2.0);

      // Uncertainty should decrease after measurement update
      expect(eskf.positionUncertainty, lessThan(initialUncertainty));
    });
  });

  group('GNSS Outage State Machine', () {
    test('State transitions: STRONG -> DEGRADED -> DENIED -> REACQUIRING -> STRONG', () {
      final fsm = GnssStateMachine();
      expect(fsm.quality, GnssQuality.strong);
      expect(fsm.navMode, NavMode.gnssIns);

      // 1. High accuracy update maintains STRONG
      fsm.updateWithGnss(const GnssSample(
        timestamp: 1.0,
        latitude: 24.363,
        longitude: 88.628,
        speed: 10.0,
        accuracy: 3.0,
        heading: 45.0,
        isAvailable: true,
      ));
      expect(fsm.quality, GnssQuality.strong);

      // 2. Degraded accuracy transitions to DEGRADED
      fsm.updateWithGnss(const GnssSample(
        timestamp: 2.0,
        latitude: 24.363,
        longitude: 88.628,
        speed: 10.0,
        accuracy: 25.0, // poor accuracy
        heading: 45.0,
        isAvailable: true,
      ));
      expect(fsm.quality, GnssQuality.degraded);

      // 3. Timeout (>2.5s without valid fix) triggers DENIED (Dead Reckoning)
      fsm.checkTimeout(5.5);
      expect(fsm.quality, GnssQuality.denied);
      expect(fsm.navMode, NavMode.deadReckoning);

      // 4. Signal return triggers REACQUIRING
      fsm.updateWithGnss(const GnssSample(
        timestamp: 6.0,
        latitude: 24.365,
        longitude: 88.630,
        speed: 10.0,
        accuracy: 4.0,
        heading: 45.0,
        isAvailable: true,
      ));
      expect(fsm.quality, GnssQuality.reacquiring);
      expect(fsm.navMode, NavMode.gnssRecovery);

      // 5. Subsequent valid fixes restore STRONG
      for (double t = 6.5; t <= 8.5; t += 0.5) {
        fsm.updateWithGnss(GnssSample(
          timestamp: t,
          latitude: 24.365,
          longitude: 88.630,
          speed: 10.0,
          accuracy: 3.5,
          heading: 45.0,
          isAvailable: true,
        ));
      }
      expect(fsm.quality, GnssQuality.strong);
      expect(fsm.navMode, NavMode.gnssIns);
    });
  });

  group('Map Matching & Route Snapping', () {
    test('Soft snaps close points to route and ignores off-route points', () {
      final matcher = RouteMatcher();
      final route = [
        const LatLng(24.3600, 88.6200),
        const LatLng(24.3700, 88.6200), // Straight North along lon 88.6200
      ];
      matcher.setRoute(route);

      // Point slightly east of route (10m away)
      const nearPoint = LatLng(24.3650, 88.6201);
      final (snappedNear, confNear, _) = matcher.match(nearPoint);
      expect(confNear, greaterThan(0.5));
      expect(snappedNear.longitude, closeTo(88.6200, 0.00008));

      // Point far away from route (500m away)
      const farPoint = LatLng(24.3650, 88.6280);
      final (snappedFar, confFar, _) = matcher.match(farPoint);
      expect(confFar, equals(0.0)); // Off-route, no forced snapping
      expect(snappedFar.longitude, equals(farPoint.longitude));
    });
  });

  group('Dataset Replay Adapter', () {
    test('Parses CSV data correctly', () async {
      final adapter = DatasetReplayAdapter();
      const testCsv = '''timestamp_ms,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,mag_x,mag_y,mag_z,gnss_lat,gnss_lon,gnss_speed,gnss_accuracy,gnss_available,gt_lat,gt_lon,gt_speed,gt_heading
0,0.1,0.2,-9.8,0.01,0.02,0.03,0,0,0,24.363,88.628,10.0,3.0,1,24.363,88.628,10.0,45.0
10,0.1,0.2,-9.8,0.01,0.02,0.03,0,0,0,24.363,88.628,10.0,3.0,1,24.363,88.628,10.0,45.0
20,0.1,0.2,-9.8,0.01,0.02,0.03,0,0,0,24.363,88.628,10.0,3.0,0,24.363,88.628,10.0,45.0''';

      await adapter.loadDataset(testCsv);
      expect(adapter.totalRows, equals(3));

      adapter.dispose();
    });
  });
}
