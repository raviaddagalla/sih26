import 'dart:async';

import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';

enum LocationAccess { granted, permissionDenied, serviceDisabled }

class LocationService {
  LocationService({Location? location}) : _location = location ?? Location();
  final Location _location;
  final _updates = StreamController<LatLng>.broadcast();
  StreamSubscription<LocationData>? _subscription;

  Stream<LatLng> get updates => _updates.stream;

  Future<LocationAccess> requestAccess() async {
    var enabled = await _location.serviceEnabled();
    if (!enabled) enabled = await _location.requestService();
    if (!enabled) return LocationAccess.serviceDisabled;
    var permission = await _location.hasPermission();
    if (permission == PermissionStatus.denied) permission = await _location.requestPermission();
    if (permission != PermissionStatus.granted && permission != PermissionStatus.grantedLimited) return LocationAccess.permissionDenied;
    return LocationAccess.granted;
  }

  Future<LatLng?> getCurrent() async {
    final data = await _location.getLocation();
    if (data.latitude == null || data.longitude == null) return null;
    return LatLng(data.latitude!, data.longitude!);
  }

  void start() {
    _subscription?.cancel();
    _subscription = _location.onLocationChanged.listen((data) {
      if (data.latitude != null && data.longitude != null) _updates.add(LatLng(data.latitude!, data.longitude!));
    });
  }

  void dispose() {
    _subscription?.cancel();
    _updates.close();
  }
}
