import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;

/// High-performance, pure-Dart inference engine for the trained 400-tree XGBoost velocity model.
/// Extracts the exact 93 kinematic features from 20-sample IMU temporal windows and executes
/// fast decision-tree traversal in < 0.2 ms on-device without C++/Python dependencies.
class XGBoostPredictor {
  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;

  double _baseScore = 18.354538;
  int _numTrees = 0;

  // Flattened tree arrays for fast cache-friendly traversal
  late List<List<int>> _lefts;
  late List<List<int>> _rights;
  late List<List<int>> _splits;
  late List<List<double>> _conds;
  late List<List<bool>> _defaults;

  Future<void> loadModel([String assetPath = 'assets/models/xgboost_trees.json']) async {
    if (_isLoaded) return;
    final jsonStr = await rootBundle.loadString(assetPath);
    final data = jsonDecode(jsonStr) as Map<String, dynamic>;

    _baseScore = (data['base_score'] as num).toDouble();
    final treesList = data['trees'] as List<dynamic>;
    _numTrees = treesList.length;

    _lefts = List.generate(_numTrees, (_) => <int>[]);
    _rights = List.generate(_numTrees, (_) => <int>[]);
    _splits = List.generate(_numTrees, (_) => <int>[]);
    _conds = List.generate(_numTrees, (_) => <double>[]);
    _defaults = List.generate(_numTrees, (_) => <bool>[]);

    for (int i = 0; i < _numTrees; i++) {
      final t = treesList[i] as Map<String, dynamic>;
      _lefts[i] = (t['l'] as List).map((e) => (e as num).toInt()).toList();
      _rights[i] = (t['r'] as List).map((e) => (e as num).toInt()).toList();
      _splits[i] = (t['s'] as List).map((e) => (e as num).toInt()).toList();
      _conds[i] = (t['c'] as List).map((e) => (e as num).toDouble()).toList();
      _defaults[i] = (t['d'] as List).map((e) => e as bool).toList();
    }

    _isLoaded = true;
  }

  /// Evaluates the 400 decision trees given a 93-dimensional engineered feature vector.
  double predict(List<double> features) {
    if (!_isLoaded || features.length < 93) return 0.0;

    double total = _baseScore;
    for (int t = 0; t < _numTrees; t++) {
      final lefts = _lefts[t];
      final rights = _rights[t];
      final splits = _splits[t];
      final conds = _conds[t];
      final defaults = _defaults[t];

      int node = 0;
      while (lefts[node] != -1) {
        final fIdx = splits[node];
        final thresh = conds[node];
        final val = features[fIdx];

        if (val.isNaN) {
          node = defaults[node] ? lefts[node] : rights[node];
        } else if (val < thresh) {
          node = lefts[node];
        } else {
          node = rights[node];
        }
      }
      total += conds[node];
    }

    // Velocity cannot physically be negative
    return max(0.0, total);
  }

  /// Extracts the exact 93 engineered features from a 20-sample unnormalized IMU window.
  /// Channel layout: [0]=LinAccX, [1]=LinAccY, [2]=LinAccZ, [3]=GravX, [4]=GravY, [5]=GravZ,
  ///                 [6]=GyroX, [7]=GyroY, [8]=GyroZ, [9..11]=Orientation
  List<double> extractFeatures(List<List<double>> window) {
    final n = window.length;
    final feats = <double>[];

    final ax = List<double>.filled(n, 0.0);
    final ay = List<double>.filled(n, 0.0);
    final az = List<double>.filled(n, 0.0);
    final gx = List<double>.filled(n, 0.0);
    final gy = List<double>.filled(n, 0.0);
    final gz = List<double>.filled(n, 0.0);
    final amag = List<double>.filled(n, 0.0);
    final gmag = List<double>.filled(n, 0.0);

    for (int i = 0; i < n; i++) {
      final row = window[i];
      ax[i] = row[0];
      ay[i] = row[1];
      az[i] = row[2];
      gx[i] = row[6];
      gy[i] = row[7];
      gz[i] = row[8];
      amag[i] = sqrt(ax[i] * ax[i] + ay[i] * ay[i] + az[i] * az[i]);
      gmag[i] = sqrt(gx[i] * gx[i] + gy[i] * gy[i] + gz[i] * gz[i]);
    }

    final signals = [ax, ay, az, gx, gy, gz, amag, gmag];

    // 1. Stats: mean, std, min, max, p25, p75 (8 * 6 = 48)
    for (final s in signals) {
      _addStats(s, feats);
    }

    // 2. Ranges (max - min) (8)
    for (final s in signals) {
      double mn = s[0], mx = s[0];
      for (int i = 1; i < n; i++) {
        if (s[i] < mn) mn = s[i];
        if (s[i] > mx) mx = s[i];
      }
      feats.add(mx - mn);
    }

    // 3. RMS (8)
    for (final s in signals) {
      double sumSq = 0.0;
      for (int i = 0; i < n; i++) {
        sumSq += s[i] * s[i];
      }
      feats.add(sqrt(sumSq / n));
    }

    // 4. Jerk: mean and max of |diff| for 6 raw axes (6 * 2 = 12)
    final jerkSignals = [ax, ay, az, gx, gy, gz];
    for (final s in jerkSignals) {
      double sumD = 0.0;
      double maxD = 0.0;
      for (int i = 0; i < n - 1; i++) {
        final d = (s[i + 1] - s[i]).abs();
        sumD += d;
        if (d > maxD) maxD = d;
      }
      feats.add(sumD / (n - 1));
      feats.add(maxD);
    }

    // 5. Temporal trend slope (8)
    // t normalized: t = 0..n-1, t -= (n-1)/2, denom = sum(t*t)
    final meanT = (n - 1) / 2.0;
    double denom = 0.0;
    for (int i = 0; i < n; i++) {
      final tVal = i - meanT;
      denom += tVal * tVal;
    }
    for (final s in signals) {
      double meanS = 0.0;
      for (int i = 0; i < n; i++) {
        meanS += s[i];
      }
      meanS /= n;

      double num = 0.0;
      for (int i = 0; i < n; i++) {
        num += (s[i] - meanS) * (i - meanT);
      }
      feats.add(denom > 0 ? num / denom : 0.0);
    }

    // 6. Frequency domain (FFT via real DFT for 20 points) for az and amag (2 * 4 = 8)
    _addFftFeatures(az, feats);
    _addFftFeatures(amag, feats);

    // 7. Gated Kinematic Feature: v_est = |ay| / |gz| where |gz| > 0.05 (1)
    double vSum = 0.0;
    int vCount = 0;
    for (int i = 0; i < n; i++) {
      final wAbs = gz[i].abs();
      if (wAbs > 0.05) {
        vSum += ay[i].abs() / wAbs;
        vCount++;
      }
    }
    feats.add(vCount > 0 ? vSum / vCount : 0.0);

    return feats;
  }

  void _addStats(List<double> s, List<double> out) {
    final n = s.length;
    double sum = 0.0;
    double minVal = s[0];
    double maxVal = s[0];

    for (int i = 0; i < n; i++) {
      final v = s[i];
      sum += v;
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }
    final mean = sum / n;

    double varSum = 0.0;
    for (int i = 0; i < n; i++) {
      final diff = s[i] - mean;
      varSum += diff * diff;
    }
    final std = sqrt(varSum / n);

    // Percentiles 25 and 75
    final sorted = List<double>.from(s)..sort();
    final p25 = _percentileSorted(sorted, 0.25);
    final p75 = _percentileSorted(sorted, 0.75);

    out.addAll([mean, std, minVal, maxVal, p25, p75]);
  }

  double _percentileSorted(List<double> sorted, double q) {
    final n = sorted.length;
    if (n == 0) return 0.0;
    final rank = q * (n - 1);
    final low = rank.floor();
    final high = rank.ceil();
    if (low == high) return sorted[low];
    final weight = rank - low;
    return sorted[low] * (1.0 - weight) + sorted[high] * weight;
  }

  void _addFftFeatures(List<double> s, List<double> out) {
    final n = s.length;
    final numFreqs = (n ~/ 2) + 1; // 11 frequencies for N=20
    final magnitudes = List<double>.filled(numFreqs, 0.0);

    // Compute real discrete Fourier transform
    for (int k = 1; k < numFreqs; k++) {
      double re = 0.0;
      double im = 0.0;
      final angleStep = 2.0 * pi * k / n;
      for (int t = 0; t < n; t++) {
        final angle = angleStep * t;
        re += s[t] * cos(angle);
        im -= s[t] * sin(angle);
      }
      magnitudes[k] = sqrt(re * re + im * im);
    }

    // AC components are k = 1..10
    int domIdx = 1;
    double domMag = magnitudes[1];
    for (int k = 2; k < numFreqs; k++) {
      if (magnitudes[k] > domMag) {
        domMag = magnitudes[k];
        domIdx = k;
      }
    }

    // Energy low: k in 1..3
    double eLow = 0.0;
    for (int k = 1; k <= min(3, numFreqs - 1); k++) {
      eLow += magnitudes[k] * magnitudes[k];
    }

    // Energy high: k in 4..10
    double eHigh = 0.0;
    for (int k = 4; k < numFreqs; k++) {
      eHigh += magnitudes[k] * magnitudes[k];
    }

    out.addAll([domIdx.toDouble(), domMag, eLow, eHigh]);
  }
}
