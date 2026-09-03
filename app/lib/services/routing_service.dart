import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RoutingService {
  /// Geocodes a text query into a LatLng using OpenStreetMap Nominatim
  static Future<LatLng?> searchDestination(String query) async {
    if (query.trim().isEmpty) return null;
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(query)}&format=json&limit=1');
    try {
      final response = await http.get(url, headers: {
        'User-Agent': 'IDRNavigationApp/1.0',
      });
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as List<dynamic>;
        if (data.isNotEmpty) {
          final lat = double.parse(data[0]['lat'].toString());
          final lon = double.parse(data[0]['lon'].toString());
          return LatLng(lat, lon);
        }
      }
    } catch (e) {
      print("Geocoding failed: $e");
    }
    return null;
  }

  /// Fetches a turn-by-turn route using OSRM public API
  static Future<List<LatLng>?> fetchRoute(LatLng start, LatLng end) async {
    final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/driving/${start.longitude},${start.latitude};${end.longitude},${end.latitude}?overview=full&geometries=geojson');
    try {
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['code'] == 'Ok') {
          final coordinates = data['routes'][0]['geometry']['coordinates'] as List<dynamic>;
          return coordinates.map((c) {
            final lon = (c[0] as num).toDouble();
            final lat = (c[1] as num).toDouble();
            return LatLng(lat, lon);
          }).toList();
        }
      }
    } catch (e) {
      print("Routing failed: $e");
    }
    return null;
  }
}
