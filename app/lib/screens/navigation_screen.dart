import 'dart:async';

import 'package:flutter/material.dart' hide NavigationMode;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/navigation_models.dart';
import '../services/navigation_services.dart';

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  final controller = NavigationController();
  late NavigationSnapshot snapshot = controller.current;
  late final StreamSubscription<NavigationSnapshot> subscription;
  bool showDemoPanel = true;

  @override
  void initState() {
    super.initState();
    subscription = controller.snapshots.listen((next) {
      if (mounted) setState(() => snapshot = next);
    });
    controller.start();
  }

  @override
  void dispose() {
    subscription.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDr = snapshot.mode == NavigationMode.deadReckoning;
    final center = LatLng(snapshot.latitude, snapshot.longitude);
    return Scaffold(
      backgroundColor: const Color(0xFFF6F8FB),
      body: Stack(
        children: [
          FlutterMap(
            options: MapOptions(initialCenter: center, initialZoom: 14.7, interactionOptions: const InteractionOptions(flags: InteractiveFlag.all)),
            children: [
              if (!const bool.fromEnvironment('FLUTTER_TEST')) TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.idr.navigation'),
              PolylineLayer(polylines: [Polyline(points: _route(center), color: const Color(0xFF1A73E8), strokeWidth: 6, borderStrokeWidth: 2, borderColor: Colors.white)]),
              MarkerLayer(markers: [Marker(point: center, width: 56, height: 56, child: _vehicleMarker(isDr))]),
            ],
          ),
          _topBar(isDr),
          Positioned(top: 112, right: 18, child: _mapControls()),
          Positioned(left: 18, right: 18, bottom: 18, child: _bottomSheet(isDr)),
        ],
      ),
    );
  }

  List<LatLng> _route(LatLng current) => [
        LatLng(current.latitude - .010, current.longitude - .012),
        LatLng(current.latitude - .006, current.longitude - .008),
        LatLng(current.latitude - .002, current.longitude - .004),
        current,
        LatLng(current.latitude + .003, current.longitude + .004),
        LatLng(current.latitude + .007, current.longitude + .008),
        LatLng(current.latitude + .011, current.longitude + .011),
      ];

  Widget _topBar(bool isDr) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              _roundButton(Icons.menu_rounded, () {}),
              const SizedBox(width: 10),
              Expanded(child: _statusPill(isDr)),
              const SizedBox(width: 10),
              _roundButton(Icons.person_rounded, () {}),
            ]),
          ),
        ),
      );

  Widget _statusPill(bool isDr) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(30), boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 15, offset: Offset(0, 4))]),
        child: Row(children: [
          Container(width: 11, height: 11, decoration: BoxDecoration(color: isDr ? const Color(0xFFFFA000) : const Color(0xFF1A73E8), shape: BoxShape.circle)),
          const SizedBox(width: 10),
          Expanded(child: Text(isDr ? 'AI DEAD RECKONING' : 'GPS ACTIVE', style: const TextStyle(fontFamily: 'Arial', fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: .5))),
          Text(isDr ? 'OFFLINE' : '${snapshot.accuracyMeters.toStringAsFixed(1)} m', style: TextStyle(fontFamily: 'Arial', fontSize: 10, color: isDr ? const Color(0xFF9A6200) : const Color(0xFF1A73E8), fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _mapControls() => Column(children: [
        _roundButton(Icons.add_rounded, () {}),
        const SizedBox(height: 8),
        _roundButton(Icons.remove_rounded, () {}),
        const SizedBox(height: 18),
        _roundButton(Icons.my_location_rounded, () {}),
      ]);

  Widget _roundButton(IconData icon, VoidCallback onPressed) => Material(color: Colors.white, elevation: 4, shadowColor: Colors.black26, shape: const CircleBorder(), child: InkWell(onTap: onPressed, customBorder: const CircleBorder(), child: Padding(padding: const EdgeInsets.all(13), child: Icon(icon, size: 20, color: const Color(0xFF263238)))));

  Widget _vehicleMarker(bool isDr) => Container(
        decoration: BoxDecoration(color: isDr ? const Color(0xFFFFB300) : const Color(0xFF1A73E8), shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4), boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 10)]),
        child: const Icon(Icons.navigation_rounded, color: Colors.white, size: 25),
      );

  Widget _bottomSheet(bool isDr) => SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 17, 18, 16),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(26), boxShadow: const [BoxShadow(color: Color(0x30000000), blurRadius: 22, offset: Offset(0, 7))]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(isDr ? 'Signal lost. Route preserved.' : 'You are on the fastest route.', style: const TextStyle(fontFamily: 'Georgia', fontSize: 21, color: Color(0xFF1E293B)))),
              Icon(isDr ? Icons.satellite_alt_rounded : Icons.navigation_rounded, color: isDr ? const Color(0xFFFFA000) : const Color(0xFF1A73E8), size: 28),
            ]),
            const SizedBox(height: 5),
            Text(snapshot.signalLabel, style: TextStyle(fontFamily: 'Arial', fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1, color: isDr ? const Color(0xFF9A6200) : const Color(0xFF1A73E8))),
            const SizedBox(height: 16),
            Row(children: [
              _stat('SPEED', snapshot.speedKmh.toStringAsFixed(1), 'km/h'),
              _divider(),
              _stat('HEADING', snapshot.heading.toStringAsFixed(0), '°'),
              _divider(),
              _stat('DISTANCE', snapshot.distanceKm.toStringAsFixed(2), 'km'),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: Text('${snapshot.latitude.toStringAsFixed(5)}, ${snapshot.longitude.toStringAsFixed(5)}', style: const TextStyle(fontFamily: 'Arial', fontSize: 11, color: Color(0xFF64748B)))),
              if (showDemoPanel) _demoToggle(isDr),
            ]),
          ]),
        ),
      );

  Widget _stat(String label, String value, String unit) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(fontFamily: 'Arial', fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: .8, color: Color(0xFF94A3B8))), const SizedBox(height: 5), RichText(text: TextSpan(style: const TextStyle(fontFamily: 'Georgia', color: Color(0xFF172033)), children: [TextSpan(text: value, style: const TextStyle(fontSize: 21)), TextSpan(text: ' $unit', style: const TextStyle(fontFamily: 'Arial', fontSize: 10, color: Color(0xFF64748B)))]))]));

  Widget _divider() => Container(width: 1, height: 30, margin: const EdgeInsets.symmetric(horizontal: 10), color: const Color(0xFFE2E8F0));

  Widget _demoToggle(bool isDr) => GestureDetector(
        onTap: controller.toggleDemoGps,
        child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9), decoration: BoxDecoration(color: isDr ? const Color(0xFFFFF4D6) : const Color(0xFFE8F0FE), borderRadius: BorderRadius.circular(18)), child: Row(children: [Icon(isDr ? Icons.power_settings_new_rounded : Icons.science_rounded, size: 15, color: isDr ? const Color(0xFF9A6200) : const Color(0xFF1A73E8)), const SizedBox(width: 6), Text(isDr ? 'RESTORE GPS' : 'DEMO GPS OFF', style: TextStyle(fontFamily: 'Arial', fontSize: 10, fontWeight: FontWeight.w800, color: isDr ? const Color(0xFF9A6200) : const Color(0xFF1A73E8)))])),
      );
}
