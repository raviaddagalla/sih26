import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../lib/idr_engine/core/math_utils.dart';
import '../lib/idr_engine/core/gnss_sample.dart';
import '../lib/idr_engine/core/nav_telemetry.dart';
import '../lib/idr_engine/eskf/eskf.dart';
import '../lib/idr_engine/fusion/gnss_state_machine.dart';
import '../lib/idr_engine/map_matching/route_matcher.dart';

void main() async {
  print('========================================');
  print('  IDR ENGINE AUTOMATED VERIFICATION SUITE');
  print('========================================\n');

  int passed = 0;
  int failed = 0;

  void test(String name, void Function() body) {
    try {
      body();
      print(' [PASS] $name');
      passed++;
    } catch (e, st) {
      print(' [FAIL] $name: $e');
      print(st);
      failed++;
    }
  }

  // 1. Math & Coordinate Conversions
  test('WGS84 Lat/Lon to NED and back round-trip consistency', () {
    const originLat = 24.363;
    const originLon = 88.628;
    const testLat = 24.3675;
    const testLon = 88.6310;

    final ned = GeoUtils.latLonToNed(testLat, testLon, originLat, originLon);
    assert(ned.x > 0, 'North must be > 0');
    assert(ned.y > 0, 'East must be > 0');

    final (recoveredLat, recoveredLon) = GeoUtils.nedToLatLon(ned.x, ned.y, originLat, originLon);
    final error = (recoveredLat - testLat).abs() + (recoveredLon - testLon).abs();
    assert(error < 1e-6, 'Round trip error must be < 1e-6, got $error');
  });

  test('Quaternion rotation vector and rotation matrix', () {
    final rotVec = const Vector3(0.0, 0.0, pi / 2.0); // 90 deg yaw
    final q = Quaternion.fromRotationVector(rotVec);
    final euler = q.toEuler();

    assert((euler.x - pi / 2.0).abs() < 1e-3, 'Yaw should be pi/2');
    assert(euler.y.abs() < 1e-3, 'Pitch should be 0');
    assert(euler.z.abs() < 1e-3, 'Roll should be 0');

    final rotMatrix = q.toRotationMatrix();
    final vRot = rotMatrix.multiplyVector(const Vector3(1.0, 0.0, 0.0));
    assert(vRot.x.abs() < 1e-4 && (vRot.y - 1.0).abs() < 1e-4, 'Rotated vector should be [0, 1, 0]');
  });

  // 2. ESKF Filter Tests
  test('ESKF nominal state and error covariance propagation', () {
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
        const Vector3(0.0, 0.0, -9.81), // Cancels gravity in NED
        const Vector3(0.0, 0.0, 0.0),
      );
    }

    assert(!eskf.p.x.isNaN, 'Position X must not be NaN');
    assert(!eskf.v.x.isNaN, 'Velocity X must not be NaN');
    assert((eskf.speed - 10.0).abs() < 0.5, 'Speed should remain ~10 m/s');
    assert((eskf.p.x - 10.0).abs() < 1.0, 'Displacement should be ~10 m');
  });

  test('ML Forward Velocity and NHC updates', () {
    final eskf = ESKF(
      originLat: 24.363,
      originLon: 88.628,
      initHeadingRad: 0.0,
      initSpeed: 0.0,
    );

    // Inject AI velocity: 15.0 m/s
    eskf.updateMlVelocity(15.0, 0.25);
    assert(eskf.v.x >= 11.0, 'ESKF forward velocity should increase towards 15 m/s (got ${eskf.v.x})');
    eskf.updateMlVelocity(15.0, 0.25);
    assert(eskf.v.x >= 13.0, 'Second update should converge closer to 15 m/s (got ${eskf.v.x})');

    // Non-holonomic constraints (lateral/vertical velocity ~ 0)
    eskf.updateNhc();
    assert(eskf.v.y.abs() < 0.5, 'Lateral velocity must be ~0');
    assert(eskf.v.z.abs() < 0.5, 'Vertical velocity must be ~0');
  });

  test('GNSS position update reduces uncertainty', () {
    final eskf = ESKF(
      originLat: 24.363,
      originLon: 88.628,
      initHeadingRad: 0.0,
      initSpeed: 0.0,
    );

    final initialUncertainty = eskf.positionUncertainty;
    eskf.updateGnss(24.3630, 88.6280, 2.0); // 2m accuracy
    assert(eskf.positionUncertainty < initialUncertainty, 'Uncertainty must decrease after GNSS fix');
  });

  // 3. GNSS Quality State Machine Tests
  test('GNSS State Machine: Transitions during Outage and Reacquisition', () {
    final fsm = GnssStateMachine();
    assert(fsm.quality == GnssQuality.strong, 'Initial state must be STRONG');
    assert(fsm.navMode == NavMode.gnssIns, 'Initial mode must be GNSS+INS');

    // High accuracy update -> STRONG
    fsm.updateWithGnss(const GnssSample(
      timestamp: 1.0,
      latitude: 24.363,
      longitude: 88.628,
      speed: 10.0,
      accuracy: 3.0,
      heading: 45.0,
      isAvailable: true,
    ));
    assert(fsm.quality == GnssQuality.strong, 'High accuracy should stay STRONG');

    // Degraded accuracy -> DEGRADED
    fsm.updateWithGnss(const GnssSample(
      timestamp: 2.0,
      latitude: 24.363,
      longitude: 88.628,
      speed: 10.0,
      accuracy: 25.0,
      heading: 45.0,
      isAvailable: true,
    ));
    assert(fsm.quality == GnssQuality.degraded, 'Low accuracy should transition to DEGRADED');

    // Outage timeout (>2.5s) -> DENIED (Dead Reckoning)
    fsm.checkTimeout(5.5);
    assert(fsm.quality == GnssQuality.denied, 'Outage timeout should trigger DENIED');
    assert(fsm.navMode == NavMode.deadReckoning, 'Mode must transition to DEAD RECKONING');

    // Signal recovery -> REACQUIRING
    fsm.updateWithGnss(const GnssSample(
      timestamp: 6.0,
      latitude: 24.365,
      longitude: 88.630,
      speed: 10.0,
      accuracy: 4.0,
      heading: 45.0,
      isAvailable: true,
    ));
    assert(fsm.quality == GnssQuality.reacquiring, 'Signal return should trigger REACQUIRING');
    assert(fsm.navMode == NavMode.gnssRecovery, 'Mode must transition to GNSS RECOVERY');

    // Multiple valid updates restore STRONG
    for (double t = 6.5; t <= 9.0; t += 0.5) {
      fsm.updateWithGnss(GnssSample(
        timestamp: t,
        latitude: 24.365,
        longitude: 88.630,
        speed: 10.0,
        accuracy: 3.0,
        heading: 45.0,
        isAvailable: true,
      ));
    }
    assert(fsm.quality == GnssQuality.strong, 'After 4 valid fixes, state must return to STRONG');
    assert(fsm.navMode == NavMode.gnssIns, 'Mode must return to GNSS+INS');
  });

  // 4. Map Matching Tests
  test('Route Matcher soft-snaps close points and respects off-route excursions', () {
    final matcher = RouteMatcher();
    final route = [
      const LatLng(24.3600, 88.6200),
      const LatLng(24.3700, 88.6200), // Straight North along lon 88.6200
    ];
    matcher.setRoute(route);

    // Point near route (10m East)
    const nearPt = LatLng(24.3650, 88.6201);
    final (snappedNear, confNear, _) = matcher.match(nearPt);
    assert(confNear > 0.5, 'Confidence for near point should be high');
    assert((snappedNear.longitude - 88.6200).abs() < 0.00008, 'Should snap near point towards 88.6200');

    // Point far off-route (600m East)
    const farPt = LatLng(24.3650, 88.6280);
    final (snappedFar, confFar, _) = matcher.match(farPt);
    assert(confFar == 0.0, 'Off-route confidence must be 0');
    assert(snappedFar.longitude == farPt.longitude, 'Off-route point must not be forced onto road');
  });

  // 5. CSV Parsing
  test('Dataset CSV parsing and row integrity', () {
    const testCsv = '''timestamp_ms,accel_x,accel_y,accel_z,gyro_x,gyro_y,gyro_z,mag_x,mag_y,mag_z,gnss_lat,gnss_lon,gnss_speed,gnss_accuracy,gnss_available,gt_lat,gt_lon,gt_speed,gt_heading
0,0.1,0.2,-9.8,0.01,0.02,0.03,0,0,0,24.363,88.628,10.0,3.0,1,24.363,88.628,10.0,45.0
10,0.1,0.2,-9.8,0.01,0.02,0.03,0,0,0,24.363,88.628,10.0,3.0,1,24.363,88.628,10.0,45.0
20,0.1,0.2,-9.8,0.01,0.02,0.03,0,0,0,24.363,88.628,10.0,3.0,0,24.363,88.628,10.0,45.0''';

    final lines = testCsv.split('\n');
    final rowCount = lines.where((l) => l.trim().isNotEmpty).length - 1;
    assert(rowCount == 3, 'Expected 3 parsed rows, got $rowCount');
  });

  print('\n----------------------------------------');
  print('  RESULTS: $passed passed, $failed failed');
  print('----------------------------------------');
  if (failed > 0) {
    throw Exception('$failed tests failed!');
  }
}
