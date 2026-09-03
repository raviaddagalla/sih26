import 'dart:math' as math;
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../models/navigation_models.dart';

class FusionEngine {
  PositionPoint? _position;
  double _headingDeg = 0;
  double _distanceKm = 0;
  List<LatLng>? activeRoute;

  PositionPoint? get position => _position;
  double get headingDeg => _headingDeg;
  double get distanceKm => _distanceKm;

  void seedFromGnss(Position position) {
    final next = PositionPoint(position.latitude, position.longitude);
    if (_position != null) _distanceKm += _haversineKm(_position!, next);
    _position = next;
    if (position.heading.isFinite && position.heading >= 0) _headingDeg = position.heading;
  }

  void integrateVelocity({required double velocityKmh, required double headingDeg, required double dtSeconds}) {
    if (_position == null) return;
    _headingDeg = headingDeg;
    final distanceM = velocityKmh / 3.6 * dtSeconds;
    final bearing = headingDeg * math.pi / 180;
    final lat = _position!.latitude + distanceM * math.cos(bearing) / 111320;
    final lon = _position!.longitude + distanceM * math.sin(bearing) / (111320 * math.cos(_position!.latitude * math.pi / 180));
    
    PositionPoint next = PositionPoint(lat, lon);
    
    // MAP MATCHING: Snap to route if active
    if (activeRoute != null && activeRoute!.isNotEmpty) {
       next = _snapToRoute(next);
    }
    
    _distanceKm += _haversineKm(_position!, next);
    _position = next;
  }

  PositionPoint _snapToRoute(PositionPoint pos) {
    if (activeRoute == null || activeRoute!.isEmpty) return pos;
    final p = LatLng(pos.latitude, pos.longitude);
    const dist = Distance();
    double minDist = double.infinity;
    LatLng closest = p;

    for (int i = 0; i < activeRoute!.length - 1; i++) {
      final a = activeRoute![i];
      final b = activeRoute![i + 1];
      
      // Fast segment projection (equirectangular approximation for small distances)
      final x = p.longitude - a.longitude;
      final y = p.latitude - a.latitude;
      final dx = b.longitude - a.longitude;
      final dy = b.latitude - a.latitude;
      
      final dot = x * dx + y * dy;
      final lenSq = dx * dx + dy * dy;
      final param = lenSq != 0 ? (dot / lenSq).clamp(0.0, 1.0) : -1.0;
      
      LatLng proj;
      if (param < 0) {
        proj = a;
      } else if (param == 0) {
        proj = a;
      } else if (param == 1) {
        proj = b;
      } else {
        proj = LatLng(a.latitude + param * dy, a.longitude + param * dx);
      }
      
      final d = dist.as(LengthUnit.Meter, p, proj);
      if (d < minDist) {
        minDist = d;
        closest = proj;
      }
    }
    
    // Only snap if we are within 100 meters of the road (prevents crazy snapping if route changes)
    if (minDist < 100) {
      return PositionPoint(closest.latitude, closest.longitude);
    }
    return pos;
  }

  void applyWeakGnssCorrection(Position position, double blend) {
    if (_position == null) return;
    final clamped = blend.clamp(0.0, 1.0);
    _position = PositionPoint(
      _position!.latitude + (position.latitude - _position!.latitude) * clamped,
      _position!.longitude + (position.longitude - _position!.longitude) * clamped,
    );
  }

  double _haversineKm(PositionPoint a, PositionPoint b) {
    const radius = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final x = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(a.latitude * math.pi / 180) * math.cos(b.latitude * math.pi / 180) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return radius * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }
}

class GnssService {
  Stream<Position> get positions => Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0));

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    return permission == LocationPermission.always || permission == LocationPermission.whileInUse;
  }
}
