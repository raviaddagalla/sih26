import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../core/math_utils.dart';
import 'road_network_matcher.dart';
export 'road_network_matcher.dart';

/// Result of matching estimated vehicle position to the active route polyline
/// or the broader offline OSM road network.
class RouteMatchResult {
  final LatLng snappedPosition;
  final double confidence;
  final double roadHeading;
  final int currentSegmentIndex;
  final double distanceToRoute;
  final double remainingDistanceMeters;
  final List<LatLng> slicedRemainingPoints;
  final bool isOffRoute;
  final bool isGeneralRoadSnapped;
  final String? roadType;

  const RouteMatchResult({
    required this.snappedPosition,
    required this.confidence,
    required this.roadHeading,
    required this.currentSegmentIndex,
    required this.distanceToRoute,
    required this.remainingDistanceMeters,
    required this.slicedRemainingPoints,
    required this.isOffRoute,
    this.isGeneralRoadSnapped = false,
    this.roadType,
  });
}

/// Road and planned-route constrained progressive map matching.
/// Softly constrains dead-reckoning trajectory to the calculated OSRM route,
/// tracks monotonic progress, slices the traveled route, and detects off-route deviation.
/// Seamlessly falls back to an offline OSM road network matcher when unrouted
/// or during detours / off-route excursions.
class RouteMatcher {
  final RoadNetworkMatcher roadNetworkMatcher;

  List<LatLng> _routePoints = [];
  bool _hasRoute = false;
  int _currentSegmentIndex = 0;
  int _offRouteTicks = 0;

  RouteMatcher({RoadNetworkMatcher? networkMatcher})
      : roadNetworkMatcher = networkMatcher ?? RoadNetworkMatcher();

  bool get hasRoute => _hasRoute && _routePoints.length >= 2;
  int get currentSegmentIndex => _currentSegmentIndex;
  List<LatLng> get routePoints => _routePoints;

  void setRoute(List<LatLng> points) {
    _routePoints = List.from(points);
    _hasRoute = _routePoints.length >= 2;
    _currentSegmentIndex = 0;
    _offRouteTicks = 0;
  }

  void clearRoute() {
    _routePoints.clear();
    _hasRoute = false;
    _currentSegmentIndex = 0;
    _offRouteTicks = 0;
  }

  /// Match current estimated position against the active route or broader road network.
  RouteMatchResult match(LatLng estimated, {double? vehicleHeadingDeg}) {
    if (!hasRoute) {
      // General road network snapping fallback when unrouted
      final roadMatch = roadNetworkMatcher.match(
        estimated,
        vehicleHeadingDeg: vehicleHeadingDeg,
      );
      return RouteMatchResult(
        snappedPosition: roadMatch.snappedPosition,
        confidence: roadMatch.confidence,
        roadHeading: roadMatch.roadHeading,
        currentSegmentIndex: 0,
        distanceToRoute: roadMatch.distanceToRoad,
        remainingDistanceMeters: 0.0,
        slicedRemainingPoints: const [],
        isOffRoute: false,
        isGeneralRoadSnapped: roadMatch.isSnapped,
        roadType: roadMatch.highwayType,
      );
    }

    double minDistance = double.infinity;
    LatLng bestProj = estimated;
    double bestHeading = 0.0;
    int bestSegmentIdx = _currentSegmentIndex;

    // Search window: monotonic forward search window to prevent jumping back
    final startIdx = max(0, _currentSegmentIndex - 1);
    final endIdx = min(_routePoints.length - 2, _currentSegmentIndex + 12);

    for (int i = startIdx; i <= endIdx; i++) {
      final p1 = _routePoints[i];
      final p2 = _routePoints[i + 1];

      final (dist, proj, heading) = _projectPointToSegment(estimated, p1, p2);
      if (dist < minDistance) {
        minDistance = dist;
        bestProj = proj;
        bestHeading = heading;
        bestSegmentIdx = i;
      }
    }

    // Fallback: if search window was too narrow and minDistance > 45m, check full route
    if (minDistance > 45.0) {
      for (int i = 0; i < _routePoints.length - 1; i++) {
        final p1 = _routePoints[i];
        final p2 = _routePoints[i + 1];
        final (dist, proj, heading) = _projectPointToSegment(estimated, p1, p2);
        if (dist < minDistance) {
          minDistance = dist;
          bestProj = proj;
          bestHeading = heading;
          bestSegmentIdx = i;
        }
      }
    }

    // Monotonically advance segment index if we are progressing
    if (bestSegmentIdx > _currentSegmentIndex && minDistance < 35.0) {
      _currentSegmentIndex = bestSegmentIdx;
    }

    // Soft constraint blending:
    // When close (<18m), blend strongly (0.75) to snap cleanly to road lanes
    // When moderate (18-40m), blend moderately
    // When >40m, vehicle may have turned off-route
    final double blendFactor;
    if (minDistance < 18.0) {
      blendFactor = 0.80;
    } else if (minDistance < 40.0) {
      blendFactor = ((40.0 - minDistance) / 40.0) * 0.50;
    } else {
      blendFactor = 0.0;
    }

    final lat = estimated.latitude * (1.0 - blendFactor) + bestProj.latitude * blendFactor;
    final lon = estimated.longitude * (1.0 - blendFactor) + bestProj.longitude * blendFactor;
    final routeSnapped = LatLng(lat, lon);

    // Track off-route state (e.g. >40m for more than 30 ticks @ 10Hz = 3 seconds)
    if (minDistance > 40.0) {
      _offRouteTicks++;
    } else {
      _offRouteTicks = max(0, _offRouteTicks - 2);
    }
    final isOffRoute = _offRouteTicks > 30;

    // Off-route detour fallback: snap to broader offline OSM road network
    LatLng finalSnapped = routeSnapped;
    double finalHeading = bestHeading;
    double finalConfidence = blendFactor;
    bool isGeneralSnapped = false;
    String? matchedRoadType;

    if (isOffRoute) {
      final roadMatch = roadNetworkMatcher.match(
        estimated,
        vehicleHeadingDeg: vehicleHeadingDeg,
      );
      if (roadMatch.isSnapped) {
        finalSnapped = roadMatch.snappedPosition;
        finalHeading = roadMatch.roadHeading;
        finalConfidence = roadMatch.confidence;
        isGeneralSnapped = true;
        matchedRoadType = roadMatch.highwayType;
      }
    }

    // Build sliced remaining route points (starting from snapped position)
    final slicedPoints = <LatLng>[finalSnapped];
    for (int i = _currentSegmentIndex + 1; i < _routePoints.length; i++) {
      slicedPoints.add(_routePoints[i]);
    }

    // Calculate remaining distance in meters along the sliced route
    double remDist = 0.0;
    for (int i = 0; i < slicedPoints.length - 1; i++) {
      remDist += GeoUtils.haversineMeters(
        slicedPoints[i].latitude,
        slicedPoints[i].longitude,
        slicedPoints[i + 1].latitude,
        slicedPoints[i + 1].longitude,
      );
    }

    return RouteMatchResult(
      snappedPosition: finalSnapped,
      confidence: finalConfidence,
      roadHeading: finalHeading,
      currentSegmentIndex: _currentSegmentIndex,
      distanceToRoute: minDistance,
      remainingDistanceMeters: remDist,
      slicedRemainingPoints: slicedPoints,
      isOffRoute: isOffRoute,
      isGeneralRoadSnapped: isGeneralSnapped,
      roadType: matchedRoadType,
    );
  }

  (double dist, LatLng proj, double heading) _projectPointToSegment(LatLng pt, LatLng s, LatLng e) {
    final R = GeoUtils.earthRadius;
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
}
