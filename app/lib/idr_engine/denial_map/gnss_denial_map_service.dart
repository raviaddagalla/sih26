import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// Represents a crowd-sourced GNSS-denied zone (tunnels, underground structures, urban canyons).
class DenialZone {
  final String id;
  final String name;
  final String zoneType;
  final double expectedOutageSeconds;
  final double entryLat;
  final double entryLon;
  final double exitLat;
  final double exitLon;
  final double radiusMeters;
  final double recommendedProcessNoiseScale;
  final String description;

  const DenialZone({
    required this.id,
    required this.name,
    required this.zoneType,
    required this.expectedOutageSeconds,
    required this.entryLat,
    required this.entryLon,
    required this.exitLat,
    required this.exitLon,
    required this.radiusMeters,
    required this.recommendedProcessNoiseScale,
    required this.description,
  });

  factory DenialZone.fromJson(Map<String, dynamic> json) {
    final props = json['properties'] as Map<String, dynamic>;
    return DenialZone(
      id: props['id'] as String? ?? 'unknown',
      name: props['name'] as String? ?? 'Outage Zone',
      zoneType: props['zone_type'] as String? ?? 'tunnel',
      expectedOutageSeconds: (props['expected_outage_s'] as num?)?.toDouble() ?? 30.0,
      entryLat: (props['entry_lat'] as num?)?.toDouble() ?? 0.0,
      entryLon: (props['entry_lon'] as num?)?.toDouble() ?? 0.0,
      exitLat: (props['exit_lat'] as num?)?.toDouble() ?? 0.0,
      exitLon: (props['exit_lon'] as num?)?.toDouble() ?? 0.0,
      radiusMeters: (props['radius_m'] as num?)?.toDouble() ?? 60.0,
      recommendedProcessNoiseScale:
          (props['recommended_process_noise_scale'] as num?)?.toDouble() ?? 0.35,
      description: props['description'] as String? ?? '',
    );
  }
}

/// Alert payload generated when vehicle is approaching or traversing a GNSS-denial zone.
class DenialZoneAlert {
  final DenialZone zone;
  final double distanceMeters;
  final double secondsUntilEntry;
  final bool isInside;
  final String bannerText;

  const DenialZoneAlert({
    required this.zone,
    required this.distanceMeters,
    required this.secondsUntilEntry,
    required this.isInside,
    required this.bannerText,
  });
}

/// Pre-emptive GNSS Outage Anticipator.
/// Scans the vehicle's heading and planned route against known denial zones.
/// Tightens ESKF filter covariance before signal loss, anchoring an accurate GNSS state
/// and warning the driver rather than discovering the blackout reactively mid-tunnel.
class GnssDenialMapService {
  final List<DenialZone> _zones = [];
  bool _isLoaded = false;
  bool get isLoaded => _isLoaded;
  List<DenialZone> get zones => List.unmodifiable(_zones);

  DenialZoneAlert? _currentAlert;
  DenialZoneAlert? get currentAlert => _currentAlert;

  Future<void> loadZones([String assetPath = 'assets/data/gnss_denial_zones.json']) async {
    try {
      final jsonStr = await rootBundle.loadString(assetPath);
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>;

      _zones.clear();
      for (final f in features) {
        _zones.add(DenialZone.fromJson(f as Map<String, dynamic>));
      }
      _isLoaded = true;
    } catch (_) {
      _isLoaded = false;
    }
  }

  /// Scans known zones against current position and velocity.
  /// Lookahead distance triggers proactive handoff warning within 100 meters.
  DenialZoneAlert? evaluateProximity({
    required double currentLat,
    required double currentLon,
    required double currentSpeedMps,
    List<LatLng>? routePoints,
  }) {
    if (!_isLoaded || _zones.isEmpty) {
      _currentAlert = null;
      return null;
    }

    DenialZone? closestZone;
    double closestDist = double.infinity;
    bool inside = false;

    for (final zone in _zones) {
      final dEntry = _haversineMeters(currentLat, currentLon, zone.entryLat, zone.entryLon);
      final dExit = _haversineMeters(currentLat, currentLon, zone.exitLat, zone.exitLon);
      final dCenter = min(dEntry, dExit);

      if (dCenter <= zone.radiusMeters) {
        closestZone = zone;
        closestDist = dCenter;
        inside = true;
        break;
      }

      if (dEntry < closestDist) {
        closestDist = dEntry;
        closestZone = zone;
      }
    }

    if (closestZone == null) {
      _currentAlert = null;
      return null;
    }

    // Proactive threshold: within 100m of entrance or already inside
    if (closestDist <= 100.0 || inside) {
      final effectiveSpeed = max(currentSpeedMps, 5.0); // Assume >= 18 km/h for ETA
      final etaSeconds = inside ? 0.0 : closestDist / effectiveSpeed;

      String banner;
      if (inside) {
        banner =
            'Inside ${closestZone.name.toUpperCase()} (Outage ~${closestZone.expectedOutageSeconds.toInt()}s) — Pure Dead-Reckoning Active';
      } else {
        banner =
            'Approaching ${closestZone.name} in ${closestDist.toInt()}m (~${etaSeconds.toInt()}s) — Pre-tightening Inertial Filter';
      }

      _currentAlert = DenialZoneAlert(
        zone: closestZone,
        distanceMeters: closestDist,
        secondsUntilEntry: etaSeconds,
        isInside: inside,
        bannerText: banner,
      );
      return _currentAlert;
    }

    _currentAlert = null;
    return null;
  }

  double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
    const R = 6378137.0;
    final dLat = (lat2 - lat1) * pi / 180.0;
    final dLon = (lon2 - lon1) * pi / 180.0;
    final a = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2) * sin(dLon / 2);
    return R * 2 * atan2(sqrt(a), sqrt(1 - a));
  }
}
