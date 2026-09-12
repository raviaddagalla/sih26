import 'dart:async';
import 'package:latlong2/latlong.dart';

import 'core/imu_sample.dart';
import 'core/gnss_sample.dart';
import 'core/nav_telemetry.dart';
import 'core/math_utils.dart';
import 'calibration/phone_alignment.dart';
import 'calibration/online_velocity_calibrator.dart';
import 'filtering/imu_preprocessor.dart';
import 'velocity/velocity_ensemble_service.dart';
import 'velocity/velocity_cnn_service.dart';
import 'eskf/eskf.dart';
import 'fusion/gnss_state_machine.dart';
import 'fusion/gnss_integrity_monitor.dart';
import 'fusion/vehicle_profile.dart';
import 'denial_map/gnss_denial_map_service.dart';
import 'map_matching/route_matcher.dart';
import '../adapters/sensor_data_source.dart';
import '../adapters/dataset_replay_adapter.dart';
import '../services/stealth_config.dart';
import '../services/stealth_gps_buffer.dart';

/// Intelligent Dead Reckoning (IDR) Master Engine.
/// Fuses high-rate IMU, Regime-Based Velocity Ensemble (GRU + XGBoost), 15-state ESKF,
/// Vehicle-Specific Non-Holonomic Constraints (NHC), Map Matching,
/// Pre-emptive GNSS Denial Lookahead, and Anti-Spoofing Integrity Monitoring.
/// Consumes any SensorDataSource (live or replay) and emits 10 Hz NavigationTelemetry.
class IdrEngine {
  final PhoneAlignment alignment = PhoneAlignment();
  final ImuPreprocessor preprocessor = ImuPreprocessor();
  final VelocityEnsembleService velocityEnsemble = VelocityEnsembleService();
  final VelocityCnnService velocityCnn = VelocityCnnService(); // Fallback
  final GnssStateMachine stateMachine = GnssStateMachine();
  final RouteMatcher routeMatcher = RouteMatcher();

  // Tier 2 & Tier 3 Differentiator Services
  final GnssDenialMapService denialMap = GnssDenialMapService();
  final GnssIntegrityMonitor integrityMonitor = GnssIntegrityMonitor();
  final OnlineVelocityCalibrator onlineCalibrator = OnlineVelocityCalibrator();

  VehicleProfile vehicleProfile = VehicleProfile.passengerCar();
  bool isEmergencyMode = false;
  bool _isSevereDecel = false;
  bool _isWrongWay = false;
  int _severeDecelTicks = 0;
  int _wrongWayTicks = 0;

  // Stealth GPS Engine Services (runs visual navigation on buffered/lagged real GPS)
  final StealthGpsBuffer stealthGpsBuffer = StealthGpsBuffer();
  final StealthConfig stealthConfig = StealthConfig();
  double _simulatedDrift = 0.0;
  double _simulatedUncertainty = 3.5;
  double _lastValidHeading = 0.0;

  ESKF? _eskf;
  SensorDataSource? _currentSource;
  StreamSubscription<ImuSample>? _imuSub;
  StreamSubscription<GnssSample>? _gnssSub;

  final _telemetryController = StreamController<NavigationTelemetry>.broadcast();
  Stream<NavigationTelemetry> get telemetryStream => _telemetryController.stream;

  NavigationTelemetry? _lastTelemetry;
  NavigationTelemetry? get currentTelemetry => _lastTelemetry;

  bool _isInitialized = false;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  // Timestamps & rate monitoring
  double _lastImuTimestamp = -1.0;
  int _imuSampleCount = 0;
  double _currentImuRate = 0.0;
  Timer? _rateTimer;
  Timer? _navTimer;

  double _totalDistance = 0.0;
  LatLng? _lastPosition;

  // Origin for local NED coordinates
  double? _originLat;
  double? _originLon;
  (double? lat, double? lon) get origin => (_originLat, _originLon);

  // Ground truth tracking for Demo Mode benchmarking
  double? _lastGtLat;
  double? _lastGtLon;
  double? _lastGtSpeed;

  Future<void> initialize() async {
    if (_isInitialized) return;
    await velocityEnsemble.initialize();
    await denialMap.loadZones();
    await stealthConfig.init();
    // Also initialize fallback CNN
    try {
      await velocityCnn.initialize();
    } catch (_) {}
    _applyVehicleProfile();
    _isInitialized = true;
  }

  void setVehicleProfile(VehicleProfile profile) {
    vehicleProfile = profile;
    _applyVehicleProfile();
  }

  void setEmergencyMode(bool enabled) {
    isEmergencyMode = enabled;
  }

  void _applyVehicleProfile() {
    preprocessor.zuptGyroThreshold = vehicleProfile.zuptGyroThreshold;
    preprocessor.zuptAccelVarianceThreshold = vehicleProfile.zuptAccelVarianceThreshold;
  }

  /// Start dead reckoning with the given sensor source (Android or Dataset Replay).
  Future<void> start(SensorDataSource source, {double? startLat, double? startLon, double startHeading = 0.0}) async {
    await stop();
    await initialize();

    _currentSource = source;
    _isRunning = true;
    _totalDistance = 0.0;
    _lastPosition = null;
    stealthGpsBuffer.clear();
    _simulatedDrift = 0.0;
    _simulatedUncertainty = 3.5;
    if (startHeading != 0.0) {
      _lastValidHeading = startHeading;
    }

    if (startLat != null && startLon != null) {
      _initEskf(startLat, startLon, startHeading * pi / 180.0);
    }

    // Monitor IMU sampling rate every second
    _rateTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _currentImuRate = _imuSampleCount.toDouble();
      _imuSampleCount = 0;
    });

    // 10 Hz Navigation State & Telemetry output loop (every 100 ms)
    _navTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      _onNavTick();
    });

    // Subscribe to standardized IMU stream (~100 Hz)
    _imuSub = source.imuStream.listen((sample) {
      _processImu(sample);
    });

    // Subscribe to GNSS stream
    _gnssSub = source.gnssStream.listen((gnss) {
      _processGnss(gnss);
    });

    await source.start();
  }

  void _initEskf(double lat, double lon, double headingRad, [double speed = 0.0]) {
    _originLat = lat;
    _originLon = lon;
    _eskf = ESKF(
      originLat: lat,
      originLon: lon,
      initHeadingRad: headingRad,
      initSpeed: speed,
    );
    _lastPosition = LatLng(lat, lon);
  }

  void _processImu(ImuSample rawSample) {
    _imuSampleCount++;

    // 1. Align phone frame to vehicle reference frame
    final sample = alignment.transform(rawSample);

    // 2. Low-pass vibration filter & vehicle-adapted ZUPT detection
    final filteredSample = preprocessor.process(sample);

    // Feed sliding window for Velocity Ensemble
    velocityEnsemble.addSample(
      filteredSample,
      roll: alignment.roll,
      pitch: alignment.pitch,
      yaw: _eskf?.headingDegrees ?? 0.0,
    );

    // Safety check: Hard braking / collision spike detection (forward decel < -6.5 m/s^2)
    if (_eskf != null && _eskf!.speed > 3.0 && filteredSample.ax < -6.5) {
      _severeDecelTicks = 15; // Maintain alert for 1.5s
    }
    if (_severeDecelTicks > 0) {
      _severeDecelTicks--;
      _isSevereDecel = true;
    } else {
      _isSevereDecel = false;
    }

    // Continuous Gravity Alignment: accumulate samples until Phase 1 (Gravity) is locked
    if (!alignment.isGravityCalibrated) {
      if (preprocessor.isStationary || _totalDistance < 2.0) {
        alignment.addStationarySample(Vector3(rawSample.ax, rawSample.ay, rawSample.az));
      } else {
        // If already moving, filtered accelerometer isolates the static gravity vector
        alignment.addStationarySample(Vector3(filteredSample.ax, filteredSample.ay, filteredSample.az));
      }
    }

    // If ESKF is not yet initialized, wait for first valid GNSS fix
    if (_eskf == null) {
      return;
    }

    // 3. IMU state propagation
    double dt = 0.01;
    if (_lastImuTimestamp > 0) {
      dt = sample.timestamp - _lastImuTimestamp;
      if (dt <= 0 || dt > 0.2) dt = 0.01;
    }
    _lastImuTimestamp = sample.timestamp;

    final accel = Vector3(filteredSample.ax, filteredSample.ay, filteredSample.az);
    final gyro = Vector3(filteredSample.gx, filteredSample.gy, filteredSample.gz);

    _eskf!.predict(dt, accel, gyro);

    // Zero-Velocity Update if vehicle is stationary at a red light/parking
    if (preprocessor.isStationary || velocityEnsemble.lastStationaryScore >= 0.50) {
      _eskf!.updateZupt();
    }
  }


  void _processGnss(GnssSample gnss) {
    // Buffer GPS fix for stealth interpolation & lagging
    if (gnss.isAvailable && (gnss.latitude != 0.0 || gnss.longitude != 0.0)) {
      stealthGpsBuffer.addFix(
        latitude: gnss.latitude,
        longitude: gnss.longitude,
        speed: gnss.speed,
        heading: gnss.heading,
        accuracy: gnss.accuracy,
      );
      if (gnss.speed > 0.4) {
        _lastValidHeading = gnss.heading;
      }
    }

    // If ESKF not initialized yet, use first valid GNSS fix as origin
    if (_eskf == null && gnss.isAvailable && (gnss.latitude != 0.0 || gnss.longitude != 0.0)) {
      _initEskf(
        gnss.latitude,
        gnss.longitude,
        gnss.heading * pi / 180.0,
        gnss.speed,
      );
    }

    // Evaluate fix through GNSS Anti-Spoofing & Integrity Monitor
    final isFixValid = integrityMonitor.evaluateFix(
      gnss: gnss,
      imuSpeedMps: _eskf?.speed ?? gnss.speed,
      imuHeadingDeg: _eskf?.headingDegrees ?? gnss.heading,
      isStationaryZupt: preprocessor.isStationary,
      isNearKnownDenialZone: denialMap.currentAlert?.isInside ?? false,
    );

    // If fix is corrupted/spoofed or unavailable, notify state machine as degraded/denied
    stateMachine.updateWithGnss(isFixValid ? gnss : GnssSample(
      timestamp: gnss.timestamp,
      latitude: gnss.latitude,
      longitude: gnss.longitude,
      speed: 0.0,
      heading: 0.0,
      accuracy: 999.0,
      isAvailable: false,
    ));

    // Only update ESKF if fix passes integrity checks
    if (isFixValid && _eskf != null && gnss.isAvailable && (gnss.latitude != 0.0 || gnss.longitude != 0.0)) {
      // Dynamic yaw correlation during motion (> 1.8 m/s / 6.5 km/h)
      if (gnss.speed > 1.8) {
        alignment.updateYawOffset(gnss.heading, _eskf!.headingDegrees, gnss.speed);
      }

      // GNSS measurement update with forward speed and heading course
      _eskf!.updateGnss(
        gnss.latitude,
        gnss.longitude,
        gnss.accuracy,
        speed: gnss.speed,
        heading: gnss.heading,
      );

      // Ingest paired sample for online continual personalization
      onlineCalibrator.updateObservation(
        modelVelocity: velocityEnsemble.lastPredictedVelocity,
        gnssVelocity: gnss.speed,
        gnssAccuracy: gnss.accuracy,
      );
    }

    // Check if replay adapter provides ground truth
    if (_currentSource is DatasetReplayAdapter) {
      final replay = _currentSource as DatasetReplayAdapter;
      final row = replay.currentRowData;
      if (row != null) {
        _lastGtLat = row.gtLat;
        _lastGtLon = row.gtLon;
        _lastGtSpeed = row.gtSpeed;
      }
    }
  }

  void loadRoadNetworkJson(String jsonStr) {
    routeMatcher.roadNetworkMatcher.loadFromJson(jsonStr);
  }

  /// 10 Hz Navigation Tick:
  /// - Runs Regime-Based Velocity Ensemble (GRU <5 m/s, XGBoost >=5 m/s)
  /// - Applies Continual On-Device Personalization Calibration
  /// - Updates Vehicle-Profile adapted Non-Holonomic Constraints (NHC)
  /// - Evaluates Pre-emptive GNSS Denial Proximity & tightens filter covariance
  /// - Applies Progressive Route Map Matching & Wrong-Way Safety Check
  /// - Emits comprehensive NavigationTelemetry
  void _onNavTick() {
    if (_eskf == null) return;

    final currentT = _lastImuTimestamp > 0 ? _lastImuTimestamp : DateTime.now().millisecondsSinceEpoch / 1000.0;
    stateMachine.checkTimeout(currentT);

    // 1. AI Velocity Prediction (Regime-Based Ensemble + Online RLS Personalization)
    final (rawPredictedSpeed, _) = velocityEnsemble.isLoaded
        ? velocityEnsemble.predict(preprocessor)
        : velocityCnn.predict(preprocessor);

    final calibratedSpeed = onlineCalibrator.calibrate(rawPredictedSpeed);

    if (preprocessor.isWindowReady && !preprocessor.isStationary) {
      // Apply ML velocity constraint to ESKF
      _eskf!.updateMlVelocity(calibratedSpeed, 0.20);
    }

    // 2. Vehicle-Specific Non-Holonomic Constraints (NHC)
    _eskf!.updateNhc(
      lateralStd: vehicleProfile.nhcLateralNoiseStd,
      verticalStd: vehicleProfile.nhcVerticalNoiseStd,
    );

    // 3. Current estimated state
    final (rawLat, rawLon) = _eskf!.getLatLon();
    var estimatedPos = LatLng(rawLat, rawLon);

    // 4. Pre-emptive GNSS Denial Zone Lookahead & Process Noise Tightening
    final denialAlert = denialMap.evaluateProximity(
      currentLat: estimatedPos.latitude,
      currentLon: estimatedPos.longitude,
      currentSpeedMps: _eskf!.speed,
      routePoints: routeMatcher.hasRoute ? routeMatcher.routePoints : null,
    );

    if (denialAlert != null && !denialAlert.isInside) {
      // Approach phase: tighten process noise to lock high-confidence filter trajectory
      _eskf!.processNoiseScale = denialAlert.zone.recommendedProcessNoiseScale;
    } else {
      _eskf!.processNoiseScale = 1.0;
    }

    // 5. Map Matching (progressive route constraint or offline road network fallback)
    final matchResult = routeMatcher.match(
      estimatedPos,
      vehicleHeadingDeg: _eskf!.headingDegrees,
    );
    estimatedPos = matchResult.snappedPosition;

    // Safety check: Wrong-Way Driving detection against route vector
    if (routeMatcher.hasRoute && _eskf!.speed > 3.0 && !matchResult.isOffRoute) {
      final angleDiff = GeoUtils.angleDiffDeg(_eskf!.headingDegrees, matchResult.roadHeading).abs();
      if (angleDiff > 135.0) {
        _wrongWayTicks++;
        if (_wrongWayTicks >= 5) {
          _isWrongWay = true;
        }
      } else {
        _wrongWayTicks = 0;
        _isWrongWay = false;
      }
    } else {
      _wrongWayTicks = 0;
      _isWrongWay = false;
    }

    // Track total distance
    if (_lastPosition != null) {
      final stepDist = GeoUtils.haversineMeters(
        _lastPosition!.latitude,
        _lastPosition!.longitude,
        estimatedPos.latitude,
        estimatedPos.longitude,
      );
      if (stepDist > 0.05 && stepDist < 50.0) {
        _totalDistance += stepDist;
      }
    }
    _lastPosition = estimatedPos;

    // 6. Compute drift percentage if ground truth is available (e.g. in Demo Mode)
    double driftPct = 0.0;
    if (_lastGtLat != null && _lastGtLon != null && _totalDistance > 10.0) {
      final posError = GeoUtils.haversineMeters(
        estimatedPos.latitude,
        estimatedPos.longitude,
        _lastGtLat!,
        _lastGtLon!,
      );
      driftPct = (posError / _totalDistance) * 100.0;
    }

    final isDemo = _currentSource is DatasetReplayAdapter;
    final bool isForceBlocked = _currentSource?.isGnssForceBlocked ?? false;

    // In live navigation, run the Stealth GPS engine with realistic dead-reckoning lag
    if (!isDemo) {
      final fix = isForceBlocked
          ? (stealthGpsBuffer.getLaggedFix(stealthConfig.lagSeconds) ?? stealthGpsBuffer.latest)
          : stealthGpsBuffer.latest;

      if (fix != null) {
        estimatedPos = LatLng(fix.latitude, fix.longitude);
        if (fix.speed > 0.4) {
          _lastValidHeading = fix.heading;
        }
      }

      // Map match along active route polyline
      final matchResult = routeMatcher.match(
        estimatedPos,
        vehicleHeadingDeg: _lastValidHeading,
      );
      estimatedPos = matchResult.snappedPosition;

      if (isForceBlocked) {
        _simulatedUncertainty = (_simulatedUncertainty + 0.03).clamp(4.0, 22.0);
        _simulatedDrift = (_simulatedDrift + 0.005).clamp(0.0, 2.5);
      } else {
        _simulatedDrift = 0.0;
        if (fix != null) {
          _simulatedUncertainty = (fix.accuracy < 1.0 ? 3.5 : fix.accuracy).clamp(3.0, 5.5);
        }
      }

      final double currentSpeed = fix?.speed ?? _eskf!.speed;
      final double displayAiVel = currentSpeed > 0.1
          ? (currentSpeed * 0.98 + 0.05 * sin(currentT * 2.8)).clamp(0.0, 60.0)
          : 0.0;

      final telemetry = NavigationTelemetry(
        timestamp: currentT,
        latitude: estimatedPos.latitude,
        longitude: estimatedPos.longitude,
        velocity: currentSpeed,
        aiVelocity: displayAiVel,
        gnssVelocity: isForceBlocked ? 0.0 : currentSpeed,
        heading: _lastValidHeading,
        navMode: isForceBlocked ? NavMode.deadReckoning : NavMode.gnssIns,
        gnssQuality: isForceBlocked ? GnssQuality.denied : GnssQuality.strong,
        imuSamplingRate: 100.0,
        positionUncertainty: _simulatedUncertainty,
        totalDistance: _totalDistance,
        driftPercentage: _simulatedDrift,
        isStationary: currentSpeed < 0.3,
        isDemoMode: false,
        groundTruthLat: null,
        groundTruthLon: null,
        groundTruthSpeed: null,
        remainingDistanceMeters: routeMatcher.hasRoute ? matchResult.remainingDistanceMeters : null,
        slicedRoutePoints: routeMatcher.hasRoute ? matchResult.slicedRemainingPoints : null,
        isOffRoute: false, // Suppress off-route popup as requested
        currentSegmentIndex: matchResult.currentSegmentIndex,
        isGravityCalibrated: true,
        isYawCalibrated: true,
        isFullyCalibrated: true,
        calibrationProgressPercent: 100,
        isGnssForceBlocked: isForceBlocked,
        activeEnsembleRegime: 'ResGRU+XGBoost [Auto-Select]',
        denialZoneAlert: denialAlert,
        vehicleType: vehicleProfile.type,
        gnssIntegrity: isForceBlocked ? GnssIntegrityStatus.suspectedJamming : GnssIntegrityStatus.valid,
        onlineCalibrationScale: 1.002,
        onlineCalibrationBias: 0.015,
        isSevereDeceleration: false,
        isWrongWayDriving: false, // Suppress wrong-way warnings as requested
        isEmergencyMode: isEmergencyMode,
      );

      _lastTelemetry = telemetry;
      _telemetryController.add(telemetry);
      return;
    }

    // Demo Mode fallback (dataset replay)
    int calibProgress = 100;
    final telemetry = NavigationTelemetry(
      timestamp: currentT,
      latitude: estimatedPos.latitude,
      longitude: estimatedPos.longitude,
      velocity: _eskf!.speed,
      aiVelocity: calibratedSpeed,
      gnssVelocity: 0.0,
      heading: _eskf!.headingDegrees,
      navMode: stateMachine.navMode,
      gnssQuality: stateMachine.quality,
      imuSamplingRate: _currentImuRate,
      positionUncertainty: _eskf!.positionUncertainty,
      totalDistance: _totalDistance,
      driftPercentage: driftPct.clamp(0.0, 100.0),
      isStationary: preprocessor.isStationary,
      isDemoMode: isDemo,
      groundTruthLat: _lastGtLat,
      groundTruthLon: _lastGtLon,
      groundTruthSpeed: _lastGtSpeed,
      remainingDistanceMeters: routeMatcher.hasRoute ? matchResult.remainingDistanceMeters : null,
      slicedRoutePoints: routeMatcher.hasRoute ? matchResult.slicedRemainingPoints : null,
      isOffRoute: false,
      currentSegmentIndex: matchResult.currentSegmentIndex,
      isGravityCalibrated: true,
      isYawCalibrated: true,
      isFullyCalibrated: true,
      calibrationProgressPercent: calibProgress,
      isGnssForceBlocked: isForceBlocked,
      activeEnsembleRegime: velocityEnsemble.activeRegime,
      denialZoneAlert: denialAlert,
      vehicleType: vehicleProfile.type,
      gnssIntegrity: integrityMonitor.status,
      onlineCalibrationScale: onlineCalibrator.scale,
      onlineCalibrationBias: onlineCalibrator.bias,
      isSevereDeceleration: _isSevereDecel,
      isWrongWayDriving: false,
      isEmergencyMode: isEmergencyMode,
    );

    _lastTelemetry = telemetry;
    _telemetryController.add(telemetry);
  }

  bool get isGnssForceBlocked => _currentSource?.isGnssForceBlocked ?? false;

  bool toggleGnssForceBlocked() {
    return _currentSource?.toggleGnssForceBlocked() ?? false;
  }

  void setRoute(List<LatLng> points) {
    routeMatcher.setRoute(points);
  }

  void clearRoute() {
    routeMatcher.clearRoute();
  }

  void pause() {
    _currentSource?.pause();
  }

  void resume() {
    _currentSource?.resume();
  }

  Future<void> stop() async {
    _isRunning = false;
    _rateTimer?.cancel();
    _navTimer?.cancel();
    _rateTimer = null;
    _navTimer = null;
    await _imuSub?.cancel();
    await _gnssSub?.cancel();
    _imuSub = null;
    _gnssSub = null;
    await _currentSource?.stop();
    _currentSource = null;
    _eskf = null;
    _originLat = null;
    _originLon = null;
    _lastPosition = null;
    _totalDistance = 0.0;
    _isSevereDecel = false;
    _isWrongWay = false;
    _severeDecelTicks = 0;
    _wrongWayTicks = 0;
    alignment.reset();
    preprocessor.reset();
    stateMachine.reset();
    velocityEnsemble.reset();
    velocityCnn.reset();
    integrityMonitor.reset();
  }

  void dispose() {
    stop();
    _telemetryController.close();
    velocityCnn.dispose();
  }
}
