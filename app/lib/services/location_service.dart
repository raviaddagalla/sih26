import 'dart:async';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';

enum LocationAccess { granted, permissionDenied, serviceDisabled }

/// Unified Location Service for the entire application.
/// Ensures single background platform channel subscription on Android to prevent dropped fixes.
class LocationService {
  LocationService({Location? location}) : _location = location ?? Location();

  final Location _location;
  final _updates = StreamController<LatLng>.broadcast();
  final _rawUpdates = StreamController<LocationData>.broadcast();
  StreamSubscription<LocationData>? _subscription;

  LocationData? _lastLocationData;
  LocationData? get lastLocationData => _lastLocationData;
  LatLng? get lastLatLng => _lastLocationData != null &&
          _lastLocationData!.latitude != null &&
          _lastLocationData!.longitude != null
      ? LatLng(_lastLocationData!.latitude!, _lastLocationData!.longitude!)
      : null;

  Stream<LatLng> get updates => _updates.stream;
  Stream<LocationData> get rawUpdates => _rawUpdates.stream;
  Location get location => _location;

  Future<LocationAccess> requestAccess() async {
    var enabled = await _location.serviceEnabled();
    if (!enabled) enabled = await _location.requestService();
    if (!enabled) return LocationAccess.serviceDisabled;

    var permission = await _location.hasPermission();
    if (permission == PermissionStatus.denied) {
      permission = await _location.requestPermission();
    }
    if (permission != PermissionStatus.granted && permission != PermissionStatus.grantedLimited) {
      return LocationAccess.permissionDenied;
    }

    try {
      await _location.changeSettings(
        accuracy: LocationAccuracy.navigation,
        interval: 1000,
        distanceFilter: 1.0,
      );
    } catch (_) {}

    return LocationAccess.granted;
  }

  Future<LatLng?> getCurrent() async {
    try {
      final data = await _location.getLocation();
      if (data.latitude == null || data.longitude == null) return null;
      _lastLocationData = data;
      return LatLng(data.latitude!, data.longitude!);
    } catch (_) {
      return null;
    }
  }

  void start() {
    _subscription?.cancel();
    _subscription = _location.onLocationChanged.listen((data) {
      _lastLocationData = data;
      if (data.latitude != null && data.longitude != null) {
        final pt = LatLng(data.latitude!, data.longitude!);
        _updates.add(pt);
      }
      _rawUpdates.add(data);
    });
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
  }

  void dispose() {
    stop();
    _updates.close();
    _rawUpdates.close();
  }
}
