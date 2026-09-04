import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class PlaceSuggestion {
  const PlaceSuggestion({required this.name, required this.address, required this.point});
  final String name;
  final String address;
  final LatLng point;
}

class GeocodingService {
  Future<List<PlaceSuggestion>> search(String query) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': query,
      'format': 'jsonv2',
      'addressdetails': '1',
      'limit': '6',
      'dedupe': '1',
    });
    final response = await http.get(uri, headers: {'User-Agent': 'NavigatePhase1/1.0 (navigation app)'});
    if (response.statusCode != 200) throw Exception('Search service returned ${response.statusCode}');
    final records = jsonDecode(response.body) as List<dynamic>;
    return records.map((item) {
      final record = item as Map<String, dynamic>;
      final display = record['display_name'] as String? ?? query;
      final parts = display.split(', ');
      return PlaceSuggestion(name: parts.first, address: parts.skip(1).take(3).join(', '), point: LatLng(double.parse(record['lat'] as String), double.parse(record['lon'] as String)));
    }).toList();
  }
}
