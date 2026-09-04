import 'package:flutter/material.dart';

import '../models/navigation_models.dart';

class NavigationPanel extends StatelessWidget {
  const NavigationPanel({super.key, required this.route, required this.isNavigating, required this.onStart, required this.onStop});
  final RouteData? route;
  final bool isNavigating;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    if (route == null) return const SizedBox.shrink();
    final distanceKm = route!.distanceMeters / 1000;
    final minutes = (route!.durationSeconds / 60).round();
    final next = route!.steps.isEmpty ? 'Follow the highlighted route' : route!.steps.first.instruction;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
      decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(28)), boxShadow: [BoxShadow(color: Color(0x26000000), blurRadius: 24, offset: Offset(0, -4))]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(isNavigating ? next : 'Route ready', style: const TextStyle(fontFamily: 'Georgia', fontSize: 22, color: Color(0xFF172033))), const SizedBox(height: 5), Text(isNavigating ? 'Next instruction' : 'Review your route and start navigation', style: const TextStyle(color: Color(0xFF64748B), fontSize: 12))])),
          const CircleAvatar(radius: 23, backgroundColor: Color(0xFFE8F0FE), child: Icon(Icons.navigation_rounded, color: Color(0xFF1A73E8))),
        ]),
        const SizedBox(height: 18),
        Row(children: [_metric('${distanceKm.toStringAsFixed(1)} km', 'distance'), _metric('$minutes min', 'ETA'), _metric('Live', 'traffic')]),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: isNavigating ? onStop : onStart, icon: Icon(isNavigating ? Icons.stop_rounded : Icons.navigation_rounded), label: Text(isNavigating ? 'END NAVIGATION' : 'START NAVIGATION'), style: FilledButton.styleFrom(backgroundColor: isNavigating ? const Color(0xFFE55B4D) : const Color(0xFF1A73E8), minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))))),
      ]),
    );
  }

  Widget _metric(String value, String label) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: Color(0xFF172033))), const SizedBox(height: 3), Text(label.toUpperCase(), style: const TextStyle(fontSize: 9, letterSpacing: .8, color: Color(0xFF94A3B8), fontWeight: FontWeight.w700))]));
}
