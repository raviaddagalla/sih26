import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../idr_engine/core/math_utils.dart';

class PlaceSuggestion {
  const PlaceSuggestion({
    required this.name,
    required this.address,
    required this.point,
    this.type,
    this.distanceMeters,
  });

  final String name;
  final String address;
  final LatLng point;
  final String? type;
  final double? distanceMeters;
}

class GeocodingService {
  final http.Client _client = http.Client();

  /// Searches for places matching [query] with fuzzy matching and proximity bias.
  /// Uses Photon (Komoot OSM) as primary fast fuzzy POI geocoder, with
  /// Nominatim proximity-viewbox + country bias as fallback.
  Future<List<PlaceSuggestion>> search(
    String query, {
    LatLng? proximity,
    String countryCode = 'in',
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return <PlaceSuggestion>[];

    // 1. Primary: Photon (fuzzy, typo-tolerant, POI-rich OSM geocoder)
    try {
      final photonResults = await _searchPhoton(cleanQuery, proximity: proximity);
      if (photonResults.isNotEmpty) {
        return _rankAndFilter(photonResults, proximity: proximity);
      }
    } catch (_) {
      // Fall through to Nominatim fallback
    }

    // 2. Secondary Fallback: Nominatim with viewbox proximity bias & country filter
    try {
      final nominatimResults = await _searchNominatim(
        cleanQuery,
        proximity: proximity,
        countryCode: countryCode,
      );
      return _rankAndFilter(nominatimResults, proximity: proximity);
    } catch (_) {
      return <PlaceSuggestion>[];
    }
  }

  Future<List<PlaceSuggestion>> _searchPhoton(
    String query, {
    LatLng? proximity,
  }) async {
    final params = <String, String>{
      'q': query,
      'limit': '10',
      'lang': 'en',
    };

    if (proximity != null) {
      params['lat'] = proximity.latitude.toStringAsFixed(6);
      params['lon'] = proximity.longitude.toStringAsFixed(6);
    }

    final uri = Uri.https('photon.komoot.io', '/api/', params);
    final response = await _client.get(
      uri,
      headers: {'User-Agent': 'IDR-Navigation/1.0 (intelligent dead reckoning)'},
    ).timeout(const Duration(seconds: 4));

    if (response.statusCode != 200) return <PlaceSuggestion>[];

    final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final features = data['features'] as List<dynamic>? ?? <dynamic>[];

    final suggestions = <PlaceSuggestion>[];
    for (final feat in features) {
      final f = feat as Map<String, dynamic>;
      final geom = f['geometry'] as Map<String, dynamic>?;
      final props = f['properties'] as Map<String, dynamic>?;
      if (geom == null || props == null) continue;

      final coords = geom['coordinates'] as List<dynamic>?;
      if (coords == null || coords.length < 2) continue;

      final lon = (coords[0] as num).toDouble();
      final lat = (coords[1] as num).toDouble();
      final point = LatLng(lat, lon);

      final name = (props['name'] as String?)?.trim() ??
          (props['street'] as String?)?.trim() ??
          query;

      // Build structured address
      final addressParts = <String>[];
      if (props['street'] != null && props['street'] != name) {
        final house = props['housenumber'] as String?;
        addressParts.add(house != null ? '${props['street']} $house' : props['street'] as String);
      }
      if (props['district'] != null) addressParts.add(props['district'] as String);
      if (props['city'] != null) addressParts.add(props['city'] as String);
      if (props['state'] != null) addressParts.add(props['state'] as String);
      if (props['country'] != null) addressParts.add(props['country'] as String);

      final address = addressParts.isNotEmpty
          ? addressParts.take(3).join(', ')
          : (props['country'] as String? ?? '');

      final osmValue = (props['osm_value'] as String?) ?? (props['type'] as String?);
      final osmKey = props['osm_key'] as String?;

      double? dist;
      if (proximity != null) {
        dist = GeoUtils.haversineMeters(
          proximity.latitude,
          proximity.longitude,
          point.latitude,
          point.longitude,
        );
      }

      suggestions.add(PlaceSuggestion(
        name: name,
        address: address,
        point: point,
        type: osmValue ?? osmKey,
        distanceMeters: dist,
      ));
    }

    return suggestions;
  }

  Future<List<PlaceSuggestion>> _searchNominatim(
    String query, {
    LatLng? proximity,
    String countryCode = 'in',
  }) async {
    final params = <String, String>{
      'q': query,
      'format': 'jsonv2',
      'addressdetails': '1',
      'limit': '8',
      'dedupe': '1',
      'countrycodes': countryCode,
    };

    // Soft proximity bias viewbox (+/- 0.5 degrees, ~55km box)
    if (proximity != null) {
      const delta = 0.5;
      final minLon = proximity.longitude - delta;
      final maxLon = proximity.longitude + delta;
      final minLat = proximity.latitude - delta;
      final maxLat = proximity.latitude + delta;
      params['viewbox'] = '$minLon,$maxLat,$maxLon,$minLat';
      params['bounded'] = '0'; // Soft bias, does not strictly exclude outside results
    }

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', params);
    final response = await _client.get(
      uri,
      headers: {'User-Agent': 'IDR-Navigation/1.0 (intelligent dead reckoning)'},
    ).timeout(const Duration(seconds: 4));

    if (response.statusCode != 200) return <PlaceSuggestion>[];

    final records = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    final suggestions = <PlaceSuggestion>[];

    for (final item in records) {
      final record = item as Map<String, dynamic>;
      final lat = double.tryParse(record['lat'] as String? ?? '');
      final lon = double.tryParse(record['lon'] as String? ?? '');
      if (lat == null || lon == null) continue;

      final point = LatLng(lat, lon);
      final displayName = record['display_name'] as String? ?? query;
      final parts = displayName.split(', ');
      final name = parts.first;
      final address = parts.skip(1).take(3).join(', ');
      final type = record['type'] as String? ?? record['class'] as String?;

      double? dist;
      if (proximity != null) {
        dist = GeoUtils.haversineMeters(
          proximity.latitude,
          proximity.longitude,
          point.latitude,
          point.longitude,
        );
      }

      suggestions.add(PlaceSuggestion(
        name: name,
        address: address,
        point: point,
        type: type,
        distanceMeters: dist,
      ));
    }

    return suggestions;
  }

  /// Ranks places prioritizing POIs (amenities, shops, commercial) and proximity.
  List<PlaceSuggestion> _rankAndFilter(
    List<PlaceSuggestion> items, {
    LatLng? proximity,
  }) {
    if (items.isEmpty) return items;

    // POI categories that should receive ranking priority over administrative boundaries
    const poiTypes = {
      'amenity', 'shop', 'restaurant', 'cafe', 'fuel', 'hospital', 'pharmacy',
      'bank', 'atm', 'supermarket', 'mall', 'hotel', 'tourism', 'building',
      'commercial', 'fast_food', 'college', 'school', 'university', 'place_of_worship'
    };

    final scored = items.map((item) {
      double score = 100.0;

      // POI type bonus
      if (item.type != null && poiTypes.contains(item.type!.toLowerCase())) {
        score += 300.0;
      }

      // Proximity scoring: exponential decay over distance (closer = much higher)
      if (item.distanceMeters != null) {
        final km = item.distanceMeters! / 1000.0;
        // Up to +500 points for nearby places within 50 km
        score += max(0.0, (50.0 - km) * 10.0);
      }

      return (item, score);
    }).toList();

    scored.sort((a, b) => b.$2.compareTo(a.$2));

    return scored.map((pair) => pair.$1).take(6).toList();
  }
}
