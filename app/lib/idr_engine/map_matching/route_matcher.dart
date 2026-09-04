import 'dart:math';
import 'package:latlong2/latlong.dart';
import '../core/math_utils.dart';

/// Road and planned-route constrained map matching.
/// Softly constrains the dead-reckoning trajectory to the calculated OSRM route,
/// mitigating heading and position drift during prolonged GNSS blackouts.
class RouteMatcher {
  List<LatLng> _routePoints = [];
  bool _hasRoute = false;

  bool get hasRoute => _hasRoute && _routePoints.length >= 2;

  void setRoute(List<LatLng> points) {
    _routePoints = List.from(points);
    _hasRoute = _routePoints.length >= 2;
  }

  void clearRoute() {
    _routePoints.clear();
    _hasRoute = false;
  }

  /// Match current estimated position against the route.
  /// Returns snapped coordinates and confidence.
  (LatLng snapped, double confidence, double roadHeading) match(LatLng estimated) {
    if (!hasRoute) {
      return (estimated, 0.0, 0.0);
    }

    double minDistance = double.infinity;
    LatLng bestProj = estimated;
    double bestHeading = 0.0;

    for (int i = 0; i < _routePoints.length - 1; i++) {
      final p1 = _routePoints[i];
      final p2 = _routePoints[i + 1];

      final (dist, proj, heading) = _projectPointToSegment(estimated, p1, p2);
      if (dist < minDistance) {
        minDistance = dist;
        bestProj = proj;
        bestHeading = heading;
      }
    }

    // Soft constraint weighting:
    // If distance < 20m, blend strongly (0.75)
    // If distance between 20m and 45m, blend moderately (0.35)
    // If distance > 45m, vehicle is off-route, do not force snapping
    final double blendFactor;
    if (minDistance < 20.0) {
      blendFactor = 0.70;
    } else if (minDistance < 45.0) {
      blendFactor = (45.0 - minDistance) / 45.0 * 0.4;
    } else {
      blendFactor = 0.0; // Off-route
    }

    final lat = estimated.latitude * (1 - blendFactor) + bestProj.latitude * blendFactor;
    final lon = estimated.longitude * (1 - blendFactor) + bestProj.longitude * blendFactor;

    return (LatLng(lat, lon), blendFactor, bestHeading);
  }

  (double dist, LatLng proj, double heading) _projectPointToSegment(LatLng pt, LatLng s, LatLng e) {
    // Local planar projection
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
