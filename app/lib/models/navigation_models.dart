import 'package:latlong2/latlong.dart';

class NavigationState {
  const NavigationState({this.userLocation, this.destination, this.route, this.isNavigating = false, this.errorMessage});
  final LatLng? userLocation;
  final LatLng? destination;
  final RouteData? route;
  final bool isNavigating;
  final String? errorMessage;

  NavigationState copyWith({LatLng? userLocation, LatLng? destination, RouteData? route, bool? isNavigating, String? errorMessage, bool clearError = false}) => NavigationState(userLocation: userLocation ?? this.userLocation, destination: destination ?? this.destination, route: route ?? this.route, isNavigating: isNavigating ?? this.isNavigating, errorMessage: clearError ? null : errorMessage ?? this.errorMessage);
}

class RouteData {
  const RouteData({required this.points, required this.distanceMeters, required this.durationSeconds, required this.steps});
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<NavigationStep> steps;
}

class NavigationStep {
  const NavigationStep({required this.instruction, required this.distanceMeters, required this.maneuver});
  final String instruction;
  final double distanceMeters;
  final String maneuver;
}
