import 'package:latlong2/latlong.dart';

class NavigationState {
  const NavigationState({
    this.userLocation,
    this.destination,
    this.route,
    this.isNavigating = false,
    this.errorMessage,
    this.currentStepIndex = 0,
    this.distanceToNextStepMeters = 0.0,
    this.remainingDistanceMeters = 0.0,
    this.remainingDurationSeconds = 0.0,
    this.isOffRoute = false,
  });

  final LatLng? userLocation;
  final LatLng? destination;
  final RouteData? route;
  final bool isNavigating;
  final String? errorMessage;
  final int currentStepIndex;
  final double distanceToNextStepMeters;
  final double remainingDistanceMeters;
  final double remainingDurationSeconds;
  final bool isOffRoute;

  NavigationStep? get currentStep {
    if (route == null || route!.steps.isEmpty) return null;
    final idx = currentStepIndex.clamp(0, route!.steps.length - 1);
    return route!.steps[idx];
  }

  NavigationState copyWith({
    LatLng? userLocation,
    LatLng? destination,
    RouteData? route,
    bool? isNavigating,
    String? errorMessage,
    int? currentStepIndex,
    double? distanceToNextStepMeters,
    double? remainingDistanceMeters,
    double? remainingDurationSeconds,
    bool? isOffRoute,
    bool clearError = false,
  }) =>
      NavigationState(
        userLocation: userLocation ?? this.userLocation,
        destination: destination ?? this.destination,
        route: route ?? this.route,
        isNavigating: isNavigating ?? this.isNavigating,
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
        currentStepIndex: currentStepIndex ?? this.currentStepIndex,
        distanceToNextStepMeters: distanceToNextStepMeters ?? this.distanceToNextStepMeters,
        remainingDistanceMeters: remainingDistanceMeters ?? this.remainingDistanceMeters,
        remainingDurationSeconds: remainingDurationSeconds ?? this.remainingDurationSeconds,
        isOffRoute: isOffRoute ?? this.isOffRoute,
      );
}

class RouteData {
  const RouteData({
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.steps,
  });

  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<NavigationStep> steps;
}

class NavigationStep {
  const NavigationStep({
    required this.instruction,
    required this.distanceMeters,
    required this.maneuver,
    this.modifier,
    this.roadName = '',
    this.location,
  });

  final String instruction;
  final double distanceMeters;
  final String maneuver; // 'turn', 'depart', 'arrive', 'roundabout', 'fork', 'merge', etc.
  final String? modifier; // 'left', 'right', 'slight left', 'slight right', etc.
  final String roadName;
  final LatLng? location;
}
