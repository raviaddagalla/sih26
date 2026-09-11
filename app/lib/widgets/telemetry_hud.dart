import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../idr_engine/core/nav_telemetry.dart';
import '../idr_engine/fusion/vehicle_profile.dart';
import '../idr_engine/fusion/gnss_integrity_monitor.dart';

/// Real-time Navigation Telemetry HUD — restyled as an iOS-style frosted
/// glass card: BackdropFilter blur, SF-Pro-ish rounded type, spring-eased
/// expand/collapse, and animated number transitions so values glide
/// instead of snapping every tick.
class TelemetryHud extends StatefulWidget {
  final NavigationTelemetry telemetry;
  final VoidCallback? onToggleForceBlackout;
  final VoidCallback? onShareLog;
  final bool isLogging;

  const TelemetryHud({
    super.key,
    required this.telemetry,
    this.onToggleForceBlackout,
    this.onShareLog,
    this.isLogging = false,
  });

  @override
  State<TelemetryHud> createState() => _TelemetryHudState();
}

class _TelemetryHudState extends State<TelemetryHud> {
  bool _expanded = false;

  void _toggleExpanded() {
    HapticFeedback.selectionClick();
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.telemetry;
    final modeColor = _getNavModeColor(t.navMode);

    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF0B0F19).withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: t.isGnssForceBlocked
                  ? const Color(0xFFFF453A).withValues(alpha: 0.40)
                  : Colors.white.withValues(alpha: 0.10),
              width: t.isGnssForceBlocked ? 1.2 : 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: t.isGnssForceBlocked
                    ? const Color(0xFFFF453A).withValues(alpha: 0.18)
                    : Colors.black.withValues(alpha: 0.28),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header row with status pills & filming blackout trigger
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 10),
                child: Row(
                  children: [
                    _pill(
                      label: t.navModeString,
                      color: modeColor,
                      icon: _getNavModeIcon(t.navMode),
                    ),
                    const SizedBox(width: 8),
                    // Tap to force GNSS blackout on/off for controlled filming
                    GestureDetector(
                      onTap: () {
                        HapticFeedback.heavyImpact();
                        widget.onToggleForceBlackout?.call();
                      },
                      child: _pill(
                        label: t.isGnssForceBlocked
                            ? 'FORCED OUTAGE'
                            : t.gnssQualityString,
                        color: t.isGnssForceBlocked
                            ? const Color(0xFFFF453A)
                            : _getGnssColor(t.gnssQuality),
                        icon: t.isGnssForceBlocked
                            ? CupertinoIcons.bolt_slash_fill
                            : CupertinoIcons.antenna_radiowaves_left_right,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _pill(
                      label: t.activeEnsembleRegime.contains('GRU') ? 'GRU AI' : 'XGB AI',
                      color: const Color(0xFF818CF8),
                      icon: Icons.memory_rounded,
                    ),
                    if (widget.isLogging) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          widget.onShareLog?.call();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFF453A).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0xFFFF453A).withValues(alpha: 0.4),
                              width: 0.8,
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(CupertinoIcons.circle_fill, size: 7, color: Color(0xFFFF453A)),
                              SizedBox(width: 4),
                              Text(
                                'REC',
                                style: TextStyle(
                                  color: Color(0xFFFF453A),
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    GestureDetector(
                      onTap: _toggleExpanded,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          shape: BoxShape.circle,
                        ),
                        child: AnimatedRotation(
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeOutCubic,
                          turns: _expanded ? 0.5 : 0.0,
                          child: const Icon(
                            CupertinoIcons.chevron_down,
                            color: Colors.white60,
                            size: 15,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Primary metrics strip
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _animatedMetric(label: 'SPEED', value: t.speedKmh, unit: 'km/h'),
                    _animatedMetric(label: 'IMU', value: t.imuSamplingRate, unit: 'Hz', decimals: 0),
                    _animatedMetric(label: 'AI VEL', value: t.aiVelocity * 3.6, unit: 'km/h'),
                    if (t.isDemoMode && t.driftPercentage > 0)
                      _animatedMetric(
                        label: 'DRIFT',
                        value: t.driftPercentage,
                        unit: '%',
                        highlight: t.driftPercentage > 10 ? const Color(0xFFFF9F0A) : const Color(0xFF30D158),
                      )
                    else
                      _animatedMetric(label: 'DIST', value: t.totalDistance / 1000.0, unit: 'km', decimals: 2),
                  ],
                ),
              ),

              // Expanded debug telemetry panel
              AnimatedSize(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                child: _expanded
                    ? Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _detailRow('Fused Position', '${t.latitude.toStringAsFixed(5)}, ${t.longitude.toStringAsFixed(5)}'),
                            _detailRow('Heading', '${t.heading.toStringAsFixed(1)}°'),
                            _detailRow('Uncertainty', '±${t.positionUncertainty.toStringAsFixed(2)} m'),
                            _detailRow('ZUPT', t.isStationary ? 'Active · Stationary' : 'Off · Moving'),
                            _detailRow(
                              'IMU Calibration',
                              t.isFullyCalibrated
                                  ? '100% · Aligned'
                                  : 'In Progress · ${t.calibrationProgressPercent}%',
                            ),
                            _detailRow(
                              'GNSS Blackout Sim',
                              t.isGnssForceBlocked
                                  ? 'FORCED OUTAGE (Tap pill to exit)'
                                  : 'Normal Live GNSS (Tap pill to trigger)',
                            ),
                            _detailRow('Ensemble Model', t.activeEnsembleRegime),
                            _detailRow(
                              'Vehicle Dynamics',
                              t.vehicleType == VehicleType.twoWheeler
                                  ? 'Two-Wheeler / Bike (Loose NHC + High ZUPT)'
                                  : (t.vehicleType == VehicleType.commercialTruck
                                      ? 'Commercial Truck (Heavy Inertia NHC)'
                                      : 'Passenger Car (Strict NHC)'),
                            ),
                            _detailRow(
                              'GNSS Integrity',
                              t.gnssIntegrity == GnssIntegrityStatus.healthy
                                  ? 'Nominal · Anti-Spoof Active'
                                  : 'ALERT · ${t.gnssIntegrity.name.toUpperCase()}',
                            ),
                            _detailRow(
                              'Continual Personalization',
                              'Scale: ${t.onlineCalibrationScale.toStringAsFixed(3)} · Bias: ${t.onlineCalibrationBias >= 0 ? '+' : ''}${t.onlineCalibrationBias.toStringAsFixed(2)} m/s',
                            ),
                            if (t.denialZoneAlert != null)
                              _detailRow(
                                'GNSS Denial Lookahead',
                                '${t.denialZoneAlert!.zone.name} · ${t.denialZoneAlert!.isInside ? "INSIDE" : "${t.denialZoneAlert!.distanceMeters.toInt()}m away"}',
                              ),
                            if (t.isDemoMode && t.groundTruthLat != null)
                              _detailRow(
                                'Ground Truth',
                                '${t.groundTruthLat!.toStringAsFixed(5)}, ${t.groundTruthLon!.toStringAsFixed(5)}',
                              ),
                            if (widget.onShareLog != null) ...[
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: TextButton.icon(
                                  onPressed: widget.onShareLog,
                                  icon: const Icon(CupertinoIcons.share_up, size: 16, color: Color(0xFF38BDF8)),
                                  label: const Text('Export & Share Live Drive CSV', style: TextStyle(color: Color(0xFF38BDF8), fontSize: 12, fontWeight: FontWeight.w600)),
                                  style: TextButton.styleFrom(
                                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill({required String label, required Color color, required IconData icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 11.5,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _animatedMetric({
    required String label,
    required double value,
    required String unit,
    int decimals = 1,
    Color? highlight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.42),
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: value, end: value),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              builder: (context, animatedValue, _) {
                return Text(
                  animatedValue.toStringAsFixed(decimals),
                  style: TextStyle(
                    color: highlight ?? Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    letterSpacing: -0.3,
                  ),
                );
              },
            ),
            const SizedBox(width: 3),
            Text(
              unit,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.35), fontSize: 10.5),
            ),
          ],
        ),
      ],
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 12)),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Color _getNavModeColor(NavMode mode) {
    switch (mode) {
      case NavMode.gnssIns:
        return const Color(0xFF30D158); // iOS system green
      case NavMode.deadReckoning:
        return const Color(0xFFFF9F0A); // iOS system orange
      case NavMode.gnssRecovery:
        return const Color(0xFF64D2FF); // iOS system cyan
    }
  }

  IconData _getNavModeIcon(NavMode mode) {
    switch (mode) {
      case NavMode.gnssIns:
        return CupertinoIcons.checkmark_seal_fill;
      case NavMode.deadReckoning:
        return CupertinoIcons.location_north_fill;
      case NavMode.gnssRecovery:
        return CupertinoIcons.arrow_2_circlepath;
    }
  }

  Color _getGnssColor(GnssQuality quality) {
    switch (quality) {
      case GnssQuality.strong:
        return const Color(0xFF30D158);
      case GnssQuality.degraded:
        return const Color(0xFFFFD60A);
      case GnssQuality.denied:
        return const Color(0xFFFF453A);
      case GnssQuality.reacquiring:
        return const Color(0xFF64D2FF);
    }
  }
}
