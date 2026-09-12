import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../idr_engine/core/nav_telemetry.dart';
import '../idr_engine/core/gnss_sample.dart';

/// Logs live vehicular telemetry (fused dead reckoning + raw GNSS fixes)
/// into high-resolution CSV files for filming validation and ground-truth comparison.
class SessionLogger {
  static final SessionLogger _instance = SessionLogger._internal();
  factory SessionLogger() => _instance;
  SessionLogger._internal();

  bool _isLogging = false;
  bool get isLogging => _isLogging;

  String? _currentFilePath;
  String? get currentLogPath => _currentFilePath;

  File? _currentFile;
  IOSink? _sink;

  int _sampleCount = 0;
  int get sampleCount => _sampleCount;

  DateTime? _startTime;
  Duration get sessionDuration =>
      _startTime != null ? DateTime.now().difference(_startTime!) : Duration.zero;

  // Most recent raw GNSS fix (persists even during simulated blackout)
  GnssSample? _latestRawGnss;

  final List<String> _writeBuffer = [];
  Timer? _flushTimer;

  /// Start a new recording session
  Future<String> startLogging() async {
    await stopLogging();

    final docsDir = await getApplicationDocumentsDirectory();
    final logDir = Directory('${docsDir.path}/idr_drive_logs');
    if (!await logDir.exists()) {
      await logDir.create(recursive: true);
    }

    final timestampStr = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '_');
    _currentFilePath = '${logDir.path}/idr_drive_$timestampStr.csv';
    _currentFile = File(_currentFilePath!);

    _sink = _currentFile!.openWrite(mode: FileMode.writeOnlyAppend);

    // Write CSV header
    _sink!.writeln(
      'timestamp_ms,rel_time_s,fused_lat,fused_lon,fused_speed_mps,fused_speed_kmh,fused_heading_deg,'
      'raw_gnss_lat,raw_gnss_lon,raw_gnss_speed_mps,raw_gnss_accuracy_m,raw_gnss_heading_deg,'
      'ai_velocity_mps,online_calib_scale,online_calib_bias,'
      'nav_mode,position_uncertainty_m,is_stationary,gnss_force_blocked',
    );

    _sampleCount = 0;
    _startTime = DateTime.now();
    _isLogging = true;
    _writeBuffer.clear();

    // Periodic flush every 2.5 seconds
    _flushTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
      _flushBuffer();
    });

    return _currentFilePath!;
  }

  /// Update latest raw GNSS fix for ground-truth pairing
  void recordRawGnss(GnssSample sample) {
    if (!_isLogging) return;
    _latestRawGnss = sample;
  }

  /// Log 10 Hz fused telemetry sample paired with latest raw GNSS
  void logTelemetry(NavigationTelemetry telem) {
    if (!_isLogging || _sink == null) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final relTimeS = sessionDuration.inMilliseconds / 1000.0;

    final rawLat = _latestRawGnss?.latitude ?? 0.0;
    final rawLon = _latestRawGnss?.longitude ?? 0.0;
    final rawSpeed = _latestRawGnss?.speed ?? 0.0;
    final rawAcc = _latestRawGnss?.accuracy ?? 999.0;
    final rawHeading = _latestRawGnss?.heading ?? 0.0;

    final line = [
      nowMs,
      relTimeS.toStringAsFixed(3),
      telem.latitude.toStringAsFixed(7),
      telem.longitude.toStringAsFixed(7),
      telem.velocity.toStringAsFixed(2),
      telem.speedKmh.toStringAsFixed(1),
      telem.heading.toStringAsFixed(1),
      rawLat != 0.0 ? rawLat.toStringAsFixed(7) : '',
      rawLon != 0.0 ? rawLon.toStringAsFixed(7) : '',
      rawSpeed != 0.0 ? rawSpeed.toStringAsFixed(2) : '',
      rawAcc < 500.0 ? rawAcc.toStringAsFixed(1) : '',
      rawHeading != 0.0 ? rawHeading.toStringAsFixed(1) : '',
      telem.aiVelocity.toStringAsFixed(2),
      telem.onlineCalibrationScale.toStringAsFixed(4),
      telem.onlineCalibrationBias.toStringAsFixed(3),
      telem.navMode.name,
      telem.positionUncertainty.toStringAsFixed(2),
      telem.isStationary ? '1' : '0',
      telem.isGnssForceBlocked ? '1' : '0',
    ].join(',');

    _writeBuffer.add(line);
    _sampleCount++;

    if (_writeBuffer.length >= 30) {
      _flushBuffer();
    }
  }

  void _flushBuffer() {
    if (_writeBuffer.isEmpty || _sink == null) return;
    final content = _writeBuffer.join('\n');
    _sink!.writeln(content);
    _writeBuffer.clear();
  }

  /// Stop current recording and flush all pending records
  Future<String?> stopLogging() async {
    if (!_isLogging) return _currentFilePath;
    _flushTimer?.cancel();
    _flushTimer = null;

    _flushBuffer();
    await _sink?.flush();
    await _sink?.close();
    _sink = null;

    _isLogging = false;
    return _currentFilePath;
  }

  /// Export / share current log file via native share sheet
  Future<void> shareCurrentLog() async {
    if (_isLogging) {
      _flushBuffer();
      await _sink?.flush();
    }

    if (_currentFilePath == null) return;
    final file = File(_currentFilePath!);
    if (!await file.exists()) return;

    await Share.shareXFiles(
      [XFile(_currentFilePath!, mimeType: 'text/csv')],
      subject: 'IDR Live Drive Telemetry Log',
      text: 'Vehicular Dead Reckoning vs GNSS Ground Truth (IO-VNBD Benchmark Track)',
    );
  }
}
