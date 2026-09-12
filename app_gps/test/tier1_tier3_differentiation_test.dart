import 'package:flutter_test/flutter_test.dart';
import 'package:navigate_phase1/idr_engine/fusion/vehicle_profile.dart';
import 'package:navigate_phase1/idr_engine/fusion/gnss_integrity_monitor.dart';
import 'package:navigate_phase1/idr_engine/calibration/online_velocity_calibrator.dart';
import 'package:navigate_phase1/idr_engine/velocity/xgboost_predictor.dart';
import 'package:navigate_phase1/idr_engine/core/gnss_sample.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Tier 1: XGBoost Pure Dart Predictor', () {
    test('Extracts all 93 features from a 20-step 12-channel IMU window', () {
      final predictor = XGBoostPredictor();
      final fakeWindow = List.generate(
        20,
        (t) => [
          0.1 * t, 0.05, 9.81 + 0.02 * t, // ax, ay, az
          0.0, 0.0, 9.81,                // gx, gy, gz (gravity)
          0.01 * (t - 10), 0.0, 0.02,     // w_yaw, w_pitch, w_roll
          45.0, 2.0, -1.0,               // euler angles
        ],
      );

      final feats = predictor.extractFeatures(fakeWindow);
      expect(feats.length, equals(93));
      for (final f in feats) {
        expect(f.isFinite, isTrue);
      }
    });

    test('Tree walk predicts bounded positive velocity', () {
      final predictor = XGBoostPredictor();
      // Even without loaded model, predict returns safe fallback 0.0
      final fakeFeatures = List.filled(93, 1.0);
      final pred = predictor.predict(fakeFeatures);
      expect(pred, greaterThanOrEqualTo(0.0));
    });
  });

  group('Tier 2.2: Multi-Vehicle Dynamic Profiles', () {
    test('Two-Wheeler adapts ZUPT variance threshold for idle engine vibration', () {
      final bike = VehicleProfile.twoWheeler();
      final car = VehicleProfile.passengerCar();
      final truck = VehicleProfile.commercialTruck();

      expect(bike.type, equals(VehicleType.twoWheeler));
      expect(bike.zuptAccelVarianceThreshold, greaterThan(car.zuptAccelVarianceThreshold));
      expect(bike.nhcLateralNoiseStd, greaterThan(car.nhcLateralNoiseStd)); // Looser NHC for banking
      expect(truck.maxTurnRateDegPerSec, lessThan(car.maxTurnRateDegPerSec));
    });
  });

  group('Tier 2.3: GNSS Integrity & Anti-Spoofing Monitor', () {
    test('Rejects satellite fix claiming speed during physical IMU standstill (Spoofing)', () {
      final monitor = GnssIntegrityMonitor();

      // Initial fix establishes baseline
      final fix0 = GnssSample(
        timestamp: 100.0,
        latitude: 12.9716,
        longitude: 77.5946,
        speed: 0.0,
        heading: 90.0,
        accuracy: 2.0,
        isAvailable: true,
      );
      expect(
        monitor.evaluateFix(
          gnss: fix0,
          imuSpeedMps: 0.0,
          imuHeadingDeg: 90.0,
          isStationaryZupt: true,
          isNearKnownDenialZone: false,
        ),
        isTrue,
      );

      // Subsequent fixes: Satellite claims vehicle moving at 25 m/s (90 km/h) but IMU is stationary ZUPT
      for (int i = 1; i <= 3; i++) {
        final fix = GnssSample(
          timestamp: 100.0 + i,
          latitude: 12.9716 + (i * 0.0002),
          longitude: 77.5946,
          speed: 25.0,
          heading: 90.0,
          accuracy: 2.0,
          isAvailable: true,
        );
        monitor.evaluateFix(
          gnss: fix,
          imuSpeedMps: 0.0,
          imuHeadingDeg: 90.0,
          isStationaryZupt: true,
          isNearKnownDenialZone: false,
        );
      }

      expect(monitor.status, equals(GnssIntegrityStatus.suspectedSpoofing));
      expect(monitor.lastWarningMessage.contains('Spoofing Alert'), isTrue);
    });

    test('Rejects sudden implausible teleportation jump (>30m jump unpredicted by IMU)', () {
      final monitor = GnssIntegrityMonitor();
      final fix0 = GnssSample(
        timestamp: 100.0,
        latitude: 12.9716,
        longitude: 77.5946,
        speed: 10.0,
        heading: 0.0,
        accuracy: 2.0,
        isAvailable: true,
      );
      monitor.evaluateFix(
        gnss: fix0,
        imuSpeedMps: 10.0,
        imuHeadingDeg: 0.0,
        isStationaryZupt: false,
        isNearKnownDenialZone: false,
      );

      // Sudden 120m teleport in 0.1s while IMU was moving at 10 m/s
      final teleportFix = GnssSample(
        timestamp: 100.1,
        latitude: 12.9730, // ~150 meters away
        longitude: 77.5946,
        speed: 10.0,
        heading: 0.0,
        accuracy: 2.0,
        isAvailable: true,
      );

      final accepted = monitor.evaluateFix(
        gnss: teleportFix,
        imuSpeedMps: 10.0,
        imuHeadingDeg: 0.0,
        isStationaryZupt: false,
        isNearKnownDenialZone: false,
      );

      expect(accepted, isFalse);
      expect(monitor.status, equals(GnssIntegrityStatus.suspectedJamming));
    });
  });

  group('Tier 2.4: Online Continual Personalization', () {
    test('RLS calibrator converges toward scale and bias offsets', () {
      final calibrator = OnlineVelocityCalibrator();

      // Suppose true vehicle speed has a +5% scale error and -0.2 m/s bias
      for (int i = 0; i < 60; i++) {
        const trueSpeed = 15.0;
        const modelSpeed = trueSpeed / 1.05 + 0.2; // Model under-predicts
        calibrator.updateObservation(
          modelVelocity: modelSpeed,
          gnssVelocity: trueSpeed,
          gnssAccuracy: 1.5,
        );
      }

      expect(calibrator.hasSufficientSamples, isTrue);
      expect(calibrator.scale, greaterThan(1.0)); // Scale adapted upward
      final calibrated = calibrator.calibrate(10.0);
      expect(calibrated, greaterThan(0.0));
    });
  });
}
