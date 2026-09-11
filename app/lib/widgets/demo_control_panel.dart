import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import '../adapters/dataset_replay_adapter.dart';

/// Interactive Demo Mode control bar — restyled with frosted glass,
/// Cupertino-weight iconography, and haptic feedback on every tap
/// so it reads as a native iOS control surface rather than a Material bar.
class DemoControlPanel extends StatelessWidget {
  final DatasetReplayAdapter replayAdapter;
  final bool isNavigating;
  final VoidCallback onStart;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRestart;
  final VoidCallback onStop;
  final ValueChanged<double> onSpeedChanged;

  const DemoControlPanel({
    super.key,
    required this.replayAdapter,
    required this.isNavigating,
    required this.onStart,
    required this.onPause,
    required this.onResume,
    required this.onRestart,
    required this.onStop,
    required this.onSpeedChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isPaused = replayAdapter.isPaused;
    final isRunning = replayAdapter.isRunning;
    final speed = replayAdapter.playbackSpeed;

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: const Color(0xFF121826).withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10), width: 0.8),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(CupertinoIcons.waveform_path, color: Color(0xFF64D2FF), size: 17),
                  const SizedBox(width: 7),
                  Text(
                    'DEMO REPLAY',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const Spacer(),
                  _speedSegmented(speed),
                ],
              ),
              const SizedBox(height: 14),
              StreamBuilder<double>(
                stream: replayAdapter.progressStream,
                initialData: 0.0,
                builder: (context, snapshot) {
                  final progress = snapshot.data ?? 0.0;
                  final currentSec = replayAdapter.currentSeconds;
                  final totalSec = replayAdapter.durationSeconds;
                  return Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween(begin: progress, end: progress),
                          duration: const Duration(milliseconds: 200),
                          builder: (context, animated, _) => LinearProgressIndicator(
                            value: animated.clamp(0.0, 1.0),
                            minHeight: 5,
                            backgroundColor: Colors.white.withValues(alpha: 0.10),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF64D2FF)),
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            _formatTime(currentSec),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 11.5,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                          Text(
                            _formatTime(totalSec),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.35),
                              fontSize: 11.5,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (!isRunning)
                    _pillButton(
                      label: 'Start Demo',
                      icon: CupertinoIcons.play_fill,
                      color: const Color(0xFF30D158),
                      onTap: onStart,
                      expand: true,
                    )
                  else ...[
                    _circleButton(icon: CupertinoIcons.gobackward, onTap: onRestart),
                    if (isPaused)
                      _pillButton(
                        label: 'Resume',
                        icon: CupertinoIcons.play_fill,
                        color: const Color(0xFF30D158),
                        onTap: onResume,
                      )
                    else
                      _pillButton(
                        label: 'Pause',
                        icon: CupertinoIcons.pause_fill,
                        color: const Color(0xFFFF9F0A),
                        onTap: onPause,
                      ),
                    _circleButton(icon: CupertinoIcons.stop_fill, onTap: onStop, color: const Color(0xFFFF453A)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _speedSegmented(double currentSpeed) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _speedChip('1×', 1.0, currentSpeed),
          _speedChip('2×', 2.0, currentSpeed),
          _speedChip('5×', 5.0, currentSpeed),
        ],
      ),
    );
  }

  Widget _speedChip(String label, double val, double currentVal) {
    final selected = (val == currentVal);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onSpeedChanged(val);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF121826) : Colors.white70,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _pillButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
    bool expand = false,
  }) {
    final button = GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 14, offset: const Offset(0, 4))],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.black.withValues(alpha: 0.75), size: 17),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: Colors.black.withValues(alpha: 0.8),
                fontWeight: FontWeight.w600,
                fontSize: 14.5,
              ),
            ),
          ],
        ),
      ),
    );
    return expand ? Expanded(child: Center(child: button)) : button;
  }

  Widget _circleButton({required IconData icon, required VoidCallback onTap, Color? color}) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        onTap();
      },
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Icon(icon, color: color ?? Colors.white70, size: 19),
      ),
    );
  }

  String _formatTime(double seconds) {
    final m = (seconds / 60).floor().toString().padLeft(2, '0');
    final s = (seconds % 60).floor().toString().padLeft(2, '0');
    return '$m:$s';
  }
}
