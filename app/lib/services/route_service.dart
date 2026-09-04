import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../models/navigation_models.dart';

class RouteService {
  Future<RouteData> calculate({required LatLng start, required LatLng end}) async {
    final uri = Uri.parse('https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson&steps=true');
    final response = await http.get(uri, headers: {'User-Agent': 'NavigatePhase1/1.0'});
    if (response.statusCode != 200) throw Exception('Could not calculate route.');
    final root = jsonDecode(response.body) as Map<String, dynamic>;
    final route = (root['routes'] as List).first as Map<String, dynamic>;
    final coordinates = ((route['geometry'] as Map<String, dynamic>)['coordinates'] as List);
    final points = coordinates.map((point) => LatLng((point[1] as num).toDouble(), (point[0] as num).toDouble())).toList();
    final leg = (route['legs'] as List).first as Map<String, dynamic>;
    final steps = ((leg['steps'] as List).cast<Map<String, dynamic>>()).map((step) {
      final maneuver = step['maneuver'] as Map<String, dynamic>;
      final modifier = maneuver['modifier'] as String?;
      final type = maneuver['type'] as String? ?? 'continue';
      return NavigationStep(instruction: _instruction(type, modifier), distanceMeters: (step['distance'] as num).toDouble(), maneuver: type);
    }).toList();
    return RouteData(points: points, distanceMeters: (route['distance'] as num).toDouble(), durationSeconds: (route['duration'] as num).toDouble(), steps: steps);
  }

  String _instruction(String type, String? modifier) {
    if (type == 'depart') return 'Head toward your destination';
    if (type == 'arrive') return 'Arrive at your destination';
    if (type == 'roundabout') return 'Enter the roundabout';
    if (modifier == null) return 'Continue straight';
    return '${modifier[0].toUpperCase()}${modifier.substring(1)}';
  }
}
