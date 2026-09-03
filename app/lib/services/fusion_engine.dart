import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../models/navigation_models.dart';

class FusionEngine {
  PositionPoint? _position;
  double _headingDeg = 0;
  double _distanceKm = 0;

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
    final next = PositionPoint(lat, lon);
    _distanceKm += _haversineKm(_position!, next);
    _position = next;
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
