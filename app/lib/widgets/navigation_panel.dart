import 'dart:ui' show ImageFilter, FontFeature;
import 'package:flutter/material.dart';

import '../models/navigation_models.dart';
import 'ios_button.dart';

class NavigationPanel extends StatelessWidget {
  const NavigationPanel({
    super.key,
    required this.route,
    required this.isNavigating,
    required this.onStart,
    required this.onStop,
  });

  final RouteData? route;
  final bool isNavigating;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    if (route == null) return const SizedBox.shrink();
    final distanceKm = route!.distanceMeters / 1000;
    final minutes = (route!.durationSeconds / 60).round();
    final next = route!.steps.isEmpty
        ? 'Follow the highlighted route'
        : route!.steps.first.instruction;

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withValues(alpha: 0.88),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border(
              top: BorderSide(
                color: Colors.white.withValues(alpha: 0.15),
                width: 0.8,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 28,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // iOS drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 5,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.28),
                      borderRadius: BorderRadius.circular(2.5),
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isNavigating ? next : 'Route Ready',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: -0.4,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            isNavigating
                                ? 'Next instruction'
                                : 'Review your route and start dead reckoning',
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 13,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF007AFF).withValues(alpha: 0.20),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF007AFF).withValues(alpha: 0.40),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.navigation_rounded,
                        color: Color(0xFF38BDF8),
                        size: 22,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    _metric('${distanceKm.toStringAsFixed(1)} km', 'DISTANCE'),
                    _metric('$minutes min', 'ETA'),
                    _metric('Offline IDR', 'NAVIGATION'),
                  ],
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: IosGlassButton(
                    onPressed: isNavigating ? onStop : onStart,
                    icon: Icon(
                      isNavigating ? Icons.stop_rounded : Icons.navigation_rounded,
                      size: 20,
                      color: Colors.white,
                    ),
                    label: isNavigating ? 'END NAVIGATION' : 'START NAVIGATION',
                    isDestructive: isNavigating,
                    backgroundColor: isNavigating
                        ? const Color(0xFFEF4444)
                        : const Color(0xFF007AFF),
                    height: 52,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _metric(String value, String label) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 0.8,
                color: Color(0xFF94A3B8),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}
