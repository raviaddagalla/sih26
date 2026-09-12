import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Configuration for simulated dead-reckoning latency and error.
/// Allows setting a value from 0 (0.0s lag, exact GPS) to 100 (2.0s lag behind real GPS).
class StealthConfig {
  static final StealthConfig _instance = StealthConfig._internal();
  factory StealthConfig() => _instance;
  StealthConfig._internal();

  int _errorSetting = 20; // Default: 20% -> 0.40s realistic inertial lag
  int get errorSetting => _errorSetting;

  /// Lag in seconds: 0 -> 0.0s, 100 -> 2.0s
  double get lagSeconds => (_errorSetting / 100.0) * 2.0;

  final ValueNotifier<int> errorSettingNotifier = ValueNotifier<int>(20);

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/stealth_config.json');
      if (await file.exists()) {
        final content = await file.readAsString();
        final map = jsonDecode(content) as Map<String, dynamic>;
        if (map.containsKey('error_setting')) {
          _errorSetting = (map['error_setting'] as num).toInt().clamp(0, 100);
          errorSettingNotifier.value = _errorSetting;
        }
      }
    } catch (_) {}
  }

  Future<void> setErrorSetting(int value) async {
    _errorSetting = value.clamp(0, 100);
    errorSettingNotifier.value = _errorSetting;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/stealth_config.json');
      await file.writeAsString(jsonEncode({'error_setting': _errorSetting}));
    } catch (_) {}
  }
}
