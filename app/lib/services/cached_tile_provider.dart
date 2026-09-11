import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';

/// High-performance disk-caching tile provider for flutter_map.
/// Caches downloaded tiles locally to prevent redundant network requests,
/// protects against OSM rate limits, and enables offline map viewing during
/// tunnels, parking structures, and GNSS blackout segments.
class CachedTileProvider extends TileProvider {
  CachedTileProvider({super.headers});

  static String? _cacheDirPath;
  static bool _initDone = false;

  static Future<void> init() async {
    if (_initDone) return;
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final dir = Directory('${docDir.path}/map_tiles_cache');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _cacheDirPath = dir.path;
      _initDone = true;
    } catch (_) {}
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    final cacheFile = _cacheDirPath != null
        ? File('$_cacheDirPath/${coordinates.z}_${coordinates.x}_${coordinates.y}.png')
        : null;

    return CachedTileImageProvider(
      url: url,
      cacheFile: cacheFile,
      headers: headers,
    );
  }

  /// Pre-caches tiles along a planned route polyline at navigation zoom levels
  /// (14, 15, 16) while a stable connection is available.
  static Future<void> precacheRoute(
    List<LatLng> points, {
    String urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
    List<int> zoomLevels = const [14, 15, 16],
    Map<String, String>? headers,
  }) async {
    if (points.isEmpty) return;
    await init();
    if (_cacheDirPath == null) return;

    final client = http.Client();
    try {
      final visitedCoords = <String>{};

      for (final zoom in zoomLevels) {
        // Sample points along route to avoid querying every single step point
        final step = points.length > 50 ? (points.length / 50).ceil() : 1;
        for (int i = 0; i < points.length; i += step) {
          final pt = points[i];
          final (tx, ty) = _latLngToTile(pt.latitude, pt.longitude, zoom);
          final key = '${zoom}_${tx}_$ty';
          if (visitedCoords.contains(key)) continue;
          visitedCoords.add(key);

          // Bounded pre-caching to preserve bandwidth and battery
          if (visitedCoords.length > 120) break;

          final file = File('$_cacheDirPath/$key.png');
          if (await file.exists()) continue;

          final url = urlTemplate
              .replaceAll('{z}', zoom.toString())
              .replaceAll('{x}', tx.toString())
              .replaceAll('{y}', ty.toString());

          try {
            final resp = await client.get(
              Uri.parse(url),
              headers: headers ?? {'User-Agent': 'IDR-Navigation/1.0 (dead reckoning)'},
            ).timeout(const Duration(seconds: 3));

            if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
              await file.writeAsBytes(resp.bodyBytes);
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  static (int x, int y) _latLngToTile(double lat, double lon, int zoom) {
    final n = 1 << zoom;
    final x = ((lon + 180.0) / 360.0 * n).floor().clamp(0, n - 1);
    final latRad = lat * pi / 180.0;
    final y = ((1.0 - log(tan(latRad) + 1.0 / cos(latRad)) / pi) / 2.0 * n).floor().clamp(0, n - 1);
    return (x, y);
  }
}

class CachedTileImageKey {
  const CachedTileImageKey(this.url, this.cachePath);
  final String url;
  final String? cachePath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CachedTileImageKey &&
          runtimeType == other.runtimeType &&
          url == other.url &&
          cachePath == other.cachePath;

  @override
  int get hashCode => Object.hash(url, cachePath);
}

class CachedTileImageProvider extends ImageProvider<CachedTileImageKey> {
  const CachedTileImageProvider({
    required this.url,
    this.cacheFile,
    this.headers,
  });

  final String url;
  final File? cacheFile;
  final Map<String, String>? headers;

  @override
  Future<CachedTileImageKey> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CachedTileImageKey>(CachedTileImageKey(url, cacheFile?.path));
  }

  @override
  ImageStreamCompleter loadImage(CachedTileImageKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: 1.0,
      debugLabel: key.url,
    );
  }

  Future<ui.Codec> _loadAsync(CachedTileImageKey key, ImageDecoderCallback decode) async {
    // 1. Try reading from local disk cache
    if (key.cachePath != null) {
      try {
        final file = File(key.cachePath!);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) {
            final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
            return decode(buffer);
          }
        }
      } catch (_) {}
    }

    // 2. Download from network
    try {
      final response = await http.get(
        Uri.parse(key.url),
        headers: headers ?? {'User-Agent': 'IDR-Navigation/1.0 (dead reckoning)'},
      ).timeout(const Duration(seconds: 4));

      if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
        // Save to disk cache asynchronously
        if (key.cachePath != null) {
          final file = File(key.cachePath!);
          file.writeAsBytes(response.bodyBytes).catchError((_) => file);
        }
        final buffer = await ui.ImmutableBuffer.fromUint8List(response.bodyBytes);
        return decode(buffer);
      }
    } catch (_) {}

    // 3. Fallback: return transparent 1x1 pixel PNG so map doesn't crash on offline/rate-limit
    final transparentPng = Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
      0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
    final buffer = await ui.ImmutableBuffer.fromUint8List(transparentPng);
    return decode(buffer);
  }
}
