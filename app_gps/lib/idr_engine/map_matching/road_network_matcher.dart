import 'dart:convert';
import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../core/math_utils.dart';

/// Represents a single directed or undirected road segment in the offline OSM network.
class RoadSegment {
  final LatLng start;
  final LatLng end;
  final String highway;
  final double headingDeg;
  final double lengthMeters;

  RoadSegment({
    required this.start,
    required this.end,
    this.highway = 'road',
  })  : headingDeg = _calcHeading(start, end),
        lengthMeters = GeoUtils.haversineMeters(
          start.latitude,
          start.longitude,
          end.latitude,
          end.longitude,
        );

  static double _calcHeading(LatLng s, LatLng e) {
    final lat1 = s.latitude * pi / 180.0;
    final lon1 = s.longitude * pi / 180.0;
    final lat2 = e.latitude * pi / 180.0;
    final lon2 = e.longitude * pi / 180.0;

    final dLon = lon2 - lon1;
    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    final deg = (atan2(y, x) * 180.0 / pi + 360.0) % 360.0;
    return deg;
  }
}

/// Result of matching a point to the offline road network.
class RoadMatchResult {
  final LatLng snappedPosition;
  final double distanceToRoad;
  final double roadHeading;
  final double confidence;
  final String highwayType;
  final bool isSnapped;

  const RoadMatchResult({
    required this.snappedPosition,
    required this.distanceToRoad,
    required this.roadHeading,
    required this.confidence,
    this.highwayType = 'road',
    required this.isSnapped,
  });

  const RoadMatchResult.none(LatLng original)
      : snappedPosition = original,
        distanceToRoad = 0.0,
        roadHeading = 0.0,
        confidence = 0.0,
        highwayType = 'none',
        isSnapped = false;
}

/// Fast spatial-hash grid indexed offline road network matcher.
/// Constrains free-roaming dead-reckoning trajectory to offline OSM road network
/// when no active route is set or when vehicle deviates from planned route.
class RoadNetworkMatcher {
  final List<RoadSegment> _segments = [];
  final Map<int, List<int>> _grid = {};

  // Grid cell size in degrees (~0.005 deg ~= 550 meters)
  static const double cellSize = 0.005;

  List<RoadSegment> get segments => List.unmodifiable(_segments);
  bool get isEmpty => _segments.isEmpty;
  int get segmentCount => _segments.length;

  int _cellHash(int cellX, int cellY) {
    return (cellX * 73856093) ^ (cellY * 19349663);
  }

  (int, int) _toCell(double lat, double lon) {
    final cx = (lon / cellSize).floor();
    final cy = (lat / cellSize).floor();
    return (cx, cy);
  }

  /// Add a road segment to the matcher and spatial hash grid.
  void addSegment(RoadSegment segment) {
    final idx = _segments.length;
    _segments.add(segment);

    final minLat = min(segment.start.latitude, segment.end.latitude);
    final maxLat = max(segment.start.latitude, segment.end.latitude);
    final minLon = min(segment.start.longitude, segment.end.longitude);
    final maxLon = max(segment.start.longitude, segment.end.longitude);

    final (minCx, minCy) = _toCell(minLat, minLon);
    final (maxCx, maxCy) = _toCell(maxLat, maxLon);

    for (int cx = minCx; cx <= maxCx; cx++) {
      for (int cy = minCy; cy <= maxCy; cy++) {
        final key = _cellHash(cx, cy);
        _grid.putIfAbsent(key, () => []).add(idx);
      }
    }
  }

  /// Batch load road segments from GeoJSON or preprocessed JSON.
  void loadFromJson(dynamic jsonData) {
    final List<dynamic> list;
    if (jsonData is String) {
      final decoded = json.decode(jsonData);
      list = (decoded is Map && decoded.containsKey('segments')) ? decoded['segments'] as List : (decoded as List);
    } else if (jsonData is Map && jsonData.containsKey('segments')) {
      list = jsonData['segments'] as List;
    } else if (jsonData is List) {
      list = jsonData;
    } else {
      return;
    }

    for (final item in list) {
      if (item is Map) {
        final s = item['start'];
        final e = item['end'];
        if (s is List && s.length >= 2 && e is List && e.length >= 2) {
          final start = LatLng((s[0] as num).toDouble(), (s[1] as num).toDouble());
          final end = LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble());
          final highway = (item['highway'] as String?) ?? 'road';
          addSegment(RoadSegment(start: start, end: end, highway: highway));
        }
      }
    }
  }

  /// Match estimated position against nearest road in the spatial network.
  RoadMatchResult match(
    LatLng estimated, {
    double maxSnapDistanceMeters = 50.0,
    double? vehicleHeadingDeg,
  }) {
    if (_segments.isEmpty) {
      return RoadMatchResult.none(estimated);
    }

    final (cx, cy) = _toCell(estimated.latitude, estimated.longitude);
    final candidateIndices = <int>{};

    // Query 3x3 surrounding grid cells
    for (int dx = -1; dx <= 1; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final key = _cellHash(cx + dx, cy + dy);
        final list = _grid[key];
        if (list != null) {
          candidateIndices.addAll(list);
        }
      }
    }

    // Fallback: If grid lookup found nothing nearby, check all segments if small enough
    Iterable<int> toSearch = candidateIndices;
    if (candidateIndices.isEmpty && _segments.length <= 150) {
      toSearch = Iterable<int>.generate(_segments.length);
    }

    double bestCost = double.infinity;
    double bestDist = double.infinity;
    LatLng bestProj = estimated;
    double bestHeading = 0.0;
    String bestHighway = 'road';

    for (final idx in toSearch) {
      final seg = _segments[idx];
      final (dist, proj, segHeading) = _projectPointToSegment(estimated, seg.start, seg.end);

      if (dist > maxSnapDistanceMeters * 1.8) continue;

      // Heading alignment penalty (if vehicle is moving with known heading)
      double headingScore = 1.0;
      double alignedHeading = segHeading;
      if (vehicleHeadingDeg != null) {
        final fwdDiff = (GeoUtils.wrapDegrees(vehicleHeadingDeg - segHeading)).abs();
        final revDiff = (GeoUtils.wrapDegrees(vehicleHeadingDeg - ((segHeading + 180.0) % 360.0))).abs();

        if (fwdDiff <= revDiff) {
          headingScore = max(0.0, 1.0 - (fwdDiff / 90.0));
          alignedHeading = segHeading;
        } else {
          headingScore = max(0.0, 1.0 - (revDiff / 90.0));
          alignedHeading = (segHeading + 180.0) % 360.0;
        }
      }

      // Cost combines geometric distance and heading alignment
      final cost = dist + (1.0 - headingScore) * 18.0;

      if (cost < bestCost) {
        bestCost = cost;
        bestDist = dist;
        bestProj = proj;
        bestHeading = alignedHeading;
        bestHighway = seg.highway;
      }
    }

    if (bestDist > maxSnapDistanceMeters) {
      return RoadMatchResult(
        snappedPosition: estimated,
        distanceToRoad: bestDist,
        roadHeading: bestHeading,
        confidence: 0.0,
        highwayType: bestHighway,
        isSnapped: false,
      );
    }

    // Soft lane-snapping blend:
    // When <12m: strong snap (0.85)
    // Between 12m and max: linear blend down to 0
    final double blendFactor;
    if (bestDist < 12.0) {
      blendFactor = 0.85;
    } else {
      blendFactor = max(0.0, (maxSnapDistanceMeters - bestDist) / maxSnapDistanceMeters) * 0.65;
    }

    final snappedLat = estimated.latitude * (1.0 - blendFactor) + bestProj.latitude * blendFactor;
    final snappedLon = estimated.longitude * (1.0 - blendFactor) + bestProj.longitude * blendFactor;
    final snappedPoint = LatLng(snappedLat, snappedLon);

    return RoadMatchResult(
      snappedPosition: snappedPoint,
      distanceToRoad: bestDist,
      roadHeading: bestHeading,
      confidence: blendFactor,
      highwayType: bestHighway,
      isSnapped: blendFactor > 0.1,
    );
  }

  (double dist, LatLng proj, double heading) _projectPointToSegment(LatLng pt, LatLng s, LatLng e) {
    const R = 6371000.0;
    final latRad = s.latitude * pi / 180.0;

    final px = pt.longitude * (pi / 180.0) * R * cos(latRad);
    final py = pt.latitude * (pi / 180.0) * R;

    final sx = s.longitude * (pi / 180.0) * R * cos(latRad);
    final sy = s.latitude * (pi / 180.0) * R;

    final ex = e.longitude * (pi / 180.0) * R * cos(latRad);
    final ey = e.latitude * (pi / 180.0) * R;

    final dx = ex - sx;
    final dy = ey - sy;
    final l2 = dx * dx + dy * dy;

    final segHeading = (atan2(dx, dy) * 180.0 / pi + 360.0) % 360.0;

    if (l2 < 1e-6) {
      return (GeoUtils.haversineMeters(pt.latitude, pt.longitude, s.latitude, s.longitude), s, segHeading);
    }

    final t = ((px - sx) * dx + (py - sy) * dy) / l2;

    final double projX, projY;
    if (t < 0.0) {
      projX = sx;
      projY = sy;
    } else if (t > 1.0) {
      projX = ex;
      projY = ey;
    } else {
      projX = sx + t * dx;
      projY = sy + t * dy;
    }

    final projLon = (projX / (R * cos(latRad))) * (180.0 / pi);
    final projLat = (projY / R) * (180.0 / pi);

    final dist = sqrt((px - projX) * (px - projX) + (py - projY) * (py - projY));
    return (dist, LatLng(projLat, projLon), segHeading);
  }

  void clear() {
    _segments.clear();
    _grid.clear();
  }
}
