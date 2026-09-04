import 'dart:async';
import 'package:flutter/services.dart' show rootBundle;
import 'sensor_data_source.dart';
import '../idr_engine/core/imu_sample.dart';
import '../idr_engine/core/gnss_sample.dart';

/// Adapter that replays recorded CSV datasets (e.g. test_dataset.csv)
/// through the exact same IDR engine pipeline.
class DatasetReplayAdapter implements SensorDataSource {
  final String assetPath;
  double playbackSpeed; // 1.0, 2.0, 5.0, 10.0

  final _imuController = StreamController<ImuSample>.broadcast();
  final _gnssController = StreamController<GnssSample>.broadcast();
  final _progressController = StreamController<double>.broadcast();

  @override
  Stream<ImuSample> get imuStream => _imuController.stream;

  @override
  Stream<GnssSample> get gnssStream => _gnssController.stream;

  Stream<double> get progressStream => _progressController.stream;

  bool _isRunning = false;
  bool _isPaused = false;

  @override
  bool get isRunning => _isRunning;

  @override
  bool get isPaused => _isPaused;

  @override
  String get sourceName => 'Dataset Replay (${assetPath.split('/').last})';

  List<ReplayRow> _rows = [];
  int _currentIndex = 0;
  Timer? _timer;

  DatasetReplayAdapter({
    this.assetPath = 'assets/demo/test_dataset.csv',
    this.playbackSpeed = 1.0,
  });

  int get totalRows => _rows.length;
  int get currentRow => _currentIndex;
  double get durationSeconds => _rows.isEmpty ? 0.0 : (_rows.last.timestampMs - _rows.first.timestampMs) / 1000.0;
  double get currentSeconds => _rows.isEmpty || _currentIndex >= _rows.length ? 0.0 : (_rows[_currentIndex].timestampMs - _rows.first.timestampMs) / 1000.0;

  Future<void> loadDataset([String? csvContent]) async {
    final String content;
    if (csvContent != null) {
      content = csvContent;
    } else {
      content = await rootBundle.loadString(assetPath);
    }

    final lines = content.split('\n');
    if (lines.isEmpty) return;

    final header = lines.first.trim().split(',');
    final colMap = <String, int>{};
    for (int i = 0; i < header.length; i++) {
      colMap[header[i].trim()] = i;
    }

    final parsedRows = <ReplayRow>[];
    for (int i = 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      final parts = line.split(',');
      if (parts.length < header.length) continue;

      double getNum(String col) {
        final idx = colMap[col];
        if (idx == null || idx >= parts.length) return 0.0;
        return double.tryParse(parts[idx].trim()) ?? 0.0;
      }

      parsedRows.add(ReplayRow(
        timestampMs: getNum('timestamp_ms'),
        ax: getNum('accel_x'),
        ay: getNum('accel_y'),
        az: getNum('accel_z'),
        gx: getNum('gyro_x'),
        gy: getNum('gyro_y'),
        gz: getNum('gyro_z'),
        mx: getNum('mag_x'),
        my: getNum('mag_y'),
        mz: getNum('mag_z'),
        gnssLat: getNum('gnss_lat'),
        gnssLon: getNum('gnss_lon'),
        gnssSpeed: getNum('gnss_speed'),
        gnssAccuracy: getNum('gnss_accuracy'),
        gnssAvailable: getNum('gnss_available') > 0.5,
        gtLat: getNum('gt_lat'),
        gtLon: getNum('gt_lon'),
        gtSpeed: getNum('gt_speed'),
        gtHeading: getNum('gt_heading'),
      ));
    }

    _rows = parsedRows;
    _currentIndex = 0;
  }

  @override
  Future<void> start() async {
    if (_rows.isEmpty) {
      await loadDataset();
    }
    _isRunning = true;
    _isPaused = false;
    _currentIndex = 0;
    _scheduleTick();
  }

  @override
  void pause() {
    _isPaused = true;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void resume() {
    if (!_isRunning) return;
    _isPaused = false;
    _scheduleTick();
  }

  void restart() {
    pause();
    _currentIndex = 0;
    resume();
  }

  @override
  Future<void> stop() async {
    _isRunning = false;
    _isPaused = false;
    _timer?.cancel();
    _timer = null;
    _currentIndex = 0;
  }

  void setSpeed(double speed) {
    playbackSpeed = speed;
    if (_isRunning && !_isPaused) {
      _timer?.cancel();
      _scheduleTick();
    }
  }

  void _scheduleTick() {
    // Pace timer: 20 ms ticks (50 Hz timer).
    // At 1x speed (100 Hz dataset = 1 sample per 10 ms), each 20 ms tick emits 2 samples.
    // At 2x speed, each 20 ms tick emits 4 samples.
    // At 5x speed, each 20 ms tick emits 10 samples.
    const tickIntervalMs = 20;
    _timer = Timer.periodic(const Duration(milliseconds: tickIntervalMs), (timer) {
      if (!_isRunning || _isPaused) return;

      final samplesPerTick = (2 * playbackSpeed).round().clamp(1, 100);
      for (int i = 0; i < samplesPerTick; i++) {
        if (_currentIndex >= _rows.length) {
          stop();
          return;
        }

        final row = _rows[_currentIndex];
        final tSec = row.timestampMs / 1000.0;

        // Emit IMU Sample
        final imu = ImuSample(
          timestamp: tSec,
          ax: row.ax,
          ay: row.ay,
          az: row.az,
          gx: row.gx,
          gy: row.gy,
          gz: row.gz,
          mx: row.mx,
          my: row.my,
          mz: row.mz,
        );
        _imuController.add(imu);

        // Emit GNSS Sample (approx every 100ms or 1000ms, or when available changes)
        if (_currentIndex % 10 == 0) {
          final gnss = GnssSample(
            timestamp: tSec,
            latitude: row.gnssLat,
            longitude: row.gnssLon,
            speed: row.gnssSpeed,
            accuracy: row.gnssAccuracy,
            heading: row.gtHeading,
            isAvailable: row.gnssAvailable,
          );
          _gnssController.add(gnss);
        }

        _currentIndex++;
      }

      if (_rows.isNotEmpty) {
        _progressController.add(_currentIndex / _rows.length);
      }
    });
  }

  ReplayRow? get currentRowData =>
      (_currentIndex > 0 && _currentIndex <= _rows.length) ? _rows[_currentIndex - 1] : null;

  @override
  void dispose() {
    stop();
    _imuController.close();
    _gnssController.close();
    _progressController.close();
  }
}

class ReplayRow {
  final double timestampMs;
  final double ax, ay, az;
  final double gx, gy, gz;
  final double mx, my, mz;
  final double gnssLat, gnssLon, gnssSpeed, gnssAccuracy;
  final bool gnssAvailable;
  final double gtLat, gtLon, gtSpeed, gtHeading;

  const ReplayRow({
    required this.timestampMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.mx,
    required this.my,
    required this.mz,
    required this.gnssLat,
    required this.gnssLon,
    required this.gnssSpeed,
    required this.gnssAccuracy,
    required this.gnssAvailable,
    required this.gtLat,
    required this.gtLon,
    required this.gtSpeed,
    required this.gtHeading,
  });
}
