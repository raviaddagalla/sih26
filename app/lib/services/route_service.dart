import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../models/navigation_models.dart';

class RouteService {
  Future<RouteData> calculate({required LatLng start, required LatLng end}) async {
    final uri = Uri.parse(
      'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson&steps=true',
    );
    final response = await http.get(uri, headers: {'User-Agent': 'IDRNavigation/2.0'});
    if (response.statusCode != 200) throw Exception('Could not calculate route.');

    final root = jsonDecode(response.body) as Map<String, dynamic>;
    final routesList = root['routes'] as List?;
    if (routesList == null || routesList.isEmpty) {
      throw Exception('No route found between coordinates.');
    }

    final route = routesList.first as Map<String, dynamic>;
    final coordinates = (route['geometry'] as Map<String, dynamic>)['coordinates'] as List;
    final points = coordinates
        .map((point) => LatLng((point[1] as num).toDouble(), (point[0] as num).toDouble()))
        .toList();

    final leg = (route['legs'] as List).first as Map<String, dynamic>;
    final rawSteps = (leg['steps'] as List).cast<Map<String, dynamic>>();

    final steps = rawSteps.map((step) {
      final maneuver = step['maneuver'] as Map<String, dynamic>;
      final modifier = maneuver['modifier'] as String?;
      final type = maneuver['type'] as String? ?? 'continue';
      final roadName = step['name'] as String? ?? '';
      final loc = maneuver['location'] as List?;
      final locationPoint = (loc != null && loc.length >= 2)
          ? LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble())
          : null;

      return NavigationStep(
        instruction: _buildInstruction(type, modifier, roadName),
        distanceMeters: (step['distance'] as num).toDouble(),
        maneuver: type,
        modifier: modifier,
        roadName: roadName,
        location: locationPoint,
      );
    }).toList();

    return RouteData(
      points: points,
      distanceMeters: (route['distance'] as num).toDouble(),
      durationSeconds: (route['duration'] as num).toDouble(),
      steps: steps,
    );
  }

  String _buildInstruction(String type, String? modifier, String roadName) {
    String action;
    if (type == 'depart') {
      action = 'Head toward your destination';
    } else if (type == 'arrive') {
      action = 'You will arrive at your destination';
    } else if (type == 'roundabout') {
      action = 'At the roundabout, take the exit';
    } else if (type == 'turn') {
      if (modifier == 'left') {
        action = 'Turn left';
      } else if (modifier == 'right') {
        action = 'Turn right';
      } else if (modifier == 'slight left') {
        action = 'Take slight left';
      } else if (modifier == 'slight right') {
        action = 'Take slight right';
      } else if (modifier == 'sharp left') {
        action = 'Sharp left';
      } else if (modifier == 'sharp right') {
        action = 'Sharp right';
      } else if (modifier == 'uturn') {
        action = 'Make a U-turn';
      } else {
        action = 'Turn';
      }
    } else if (type == 'fork') {
      action = modifier == 'left' ? 'Take the left fork' : 'Take the right fork';
    } else if (type == 'merge') {
      action = 'Merge onto';
    } else if (type == 'on ramp') {
      action = 'Take the ramp';
    } else if (modifier != null && modifier.isNotEmpty) {
      action = '${modifier[0].toUpperCase()}${modifier.substring(1)}';
    } else {
      action = 'Continue straight';
    }

    if (roadName.trim().isNotEmpty && !action.contains(roadName)) {
      return '$action on $roadName';
    }
    return action;
  }
}
