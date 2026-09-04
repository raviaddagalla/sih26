import 'package:flutter/material.dart';
import '../idr_engine/core/nav_telemetry.dart';

/// Real-time Navigation Telemetry HUD displaying IDR engine state,
/// GNSS quality state machine, IMU frequency, and dead-reckoning drift.
class TelemetryHud extends StatefulWidget {
  final NavigationTelemetry telemetry;

  const TelemetryHud({
    super.key,
    required this.telemetry,
  });

  @override
  State<TelemetryHud> createState() => _TelemetryHudState();
}

class _TelemetryHudState extends State<TelemetryHud> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.telemetry;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 16, offset: Offset(0, 4)),
        ],
        border: Border.all(
          color: _getNavModeColor(t.navMode).withValues(alpha: 0.4),
          width: 1.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header row with status badges
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              children: [
                _badge(
                  label: t.navModeString,
                  color: _getNavModeColor(t.navMode),
                  icon: _getNavModeIcon(t.navMode),
                ),
                const SizedBox(width: 8),
                _badge(
                  label: 'GNSS: ${t.gnssQualityString}',
                  color: _getGnssColor(t.gnssQuality),
                  icon: Icons.satellite_alt_rounded,
                ),
                const Spacer(),
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      _expanded ? Icons.keyboard_arrow_up_rounded : Icons.tune_rounded,
                      color: Colors.white70,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Primary metrics strip
          Container(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _metric(
                  label: 'SPEED',
                  value: t.speedKmh.toStringAsFixed(1),
                  unit: 'km/h',
                ),
                _metric(
                  label: 'IMU RATE',
                  value: '${t.imuSamplingRate.toInt()}',
                  unit: 'Hz',
                ),
                _metric(
                  label: 'AI VELOCITY',
                  value: (t.aiVelocity * 3.6).toStringAsFixed(1),
                  unit: 'km/h',
                ),
                if (t.isDemoMode && t.driftPercentage > 0)
                  _metric(
                    label: 'DRIFT',
                    value: t.driftPercentage.toStringAsFixed(1),
                    unit: '%',
                    highlight: t.driftPercentage > 10 ? Colors.orangeAccent : const Color(0xFF10B981),
                  )
                else
                  _metric(
                    label: 'DISTANCE',
                    value: (t.totalDistance / 1000.0).toStringAsFixed(2),
                    unit: 'km',
                  ),
              ],
            ),
          ),

          // Expanded debug telemetry panel
          if (_expanded) ...[
            const Divider(color: Colors.white12, height: 1),
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black26,
              child: Column(
                children: [
                  _detailRow('Fused Position', '${t.latitude.toStringAsFixed(5)}, ${t.longitude.toStringAsFixed(5)}'),
                  _detailRow('Vehicle Heading', '${t.heading.toStringAsFixed(1)}°'),
                  _detailRow('Position Uncertainty', '±${t.positionUncertainty.toStringAsFixed(2)} m'),
                  _detailRow('Zero-Velocity (ZUPT)', t.isStationary ? 'ACTIVE (Stationary)' : 'OFF (Moving)'),
                  if (t.isDemoMode && t.groundTruthLat != null) ...[
                    const SizedBox(height: 4),
                    _detailRow(
                      'Ground Truth Fix',
                      '${t.groundTruthLat!.toStringAsFixed(5)}, ${t.groundTruthLon!.toStringAsFixed(5)}',
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _badge({required String label, required Color color, required IconData icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 11,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _metric({
    required String label,
    required String value,
    required String unit,
    Color? highlight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 0.6),
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                color: highlight ?? Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 3),
            Text(
              unit,
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white60, fontSize: 11)),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Color _getNavModeColor(NavMode mode) {
    switch (mode) {
      case NavMode.gnssIns:
        return const Color(0xFF10B981); // Emerald Green
      case NavMode.deadReckoning:
        return const Color(0xFFF59E0B); // Amber / Orange
      case NavMode.gnssRecovery:
        return const Color(0xFF38BDF8); // Cyan / Blue
    }
  }

  IconData _getNavModeIcon(NavMode mode) {
    switch (mode) {
      case NavMode.gnssIns:
        return Icons.verified_rounded;
      case NavMode.deadReckoning:
        return Icons.explore_rounded;
      case NavMode.gnssRecovery:
        return Icons.sync_rounded;
    }
  }

  Color _getGnssColor(GnssQuality quality) {
    switch (quality) {
      case GnssQuality.strong:
        return const Color(0xFF10B981);
      case GnssQuality.degraded:
        return const Color(0xFFFACC15);
      case GnssQuality.denied:
        return const Color(0xFFEF4444);
      case GnssQuality.reacquiring:
        return const Color(0xFF38BDF8);
    }
  }
}
