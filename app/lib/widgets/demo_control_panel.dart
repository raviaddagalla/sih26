import 'package:flutter/material.dart';
import '../adapters/dataset_replay_adapter.dart';

/// Interactive Demo Mode control bar and configuration overlay.
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

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(color: Colors.black26, blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.science_rounded, color: Color(0xFF38BDF8), size: 20),
              const SizedBox(width: 8),
              const Text(
                'DEMO REPLAY',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 1.0),
              ),
              const Spacer(),
              _speedChip('1x', 1.0, speed),
              const SizedBox(width: 4),
              _speedChip('2x', 2.0, speed),
              const SizedBox(width: 4),
              _speedChip('5x', 5.0, speed),
            ],
          ),
          const SizedBox(height: 10),
          StreamBuilder<double>(
            stream: replayAdapter.progressStream,
            initialData: 0.0,
            builder: (context, snapshot) {
              final progress = snapshot.data ?? 0.0;
              final currentSec = replayAdapter.currentSeconds;
              final totalSec = replayAdapter.durationSeconds;
              return Column(
                children: [
                  LinearProgressIndicator(
                    value: progress.clamp(0.0, 1.0),
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _formatTime(currentSec),
                        style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
                      ),
                      Text(
                        _formatTime(totalSec),
                        style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (!isRunning)
                FilledButton.icon(
                  onPressed: onStart,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('START DEMO'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                )
              else ...[
                IconButton.filledTonal(
                  onPressed: onRestart,
                  icon: const Icon(Icons.replay_rounded, size: 20),
                  tooltip: 'Restart',
                ),
                if (isPaused)
                  FilledButton.icon(
                    onPressed: onResume,
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('RESUME'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF10B981)),
                  )
                else
                  FilledButton.icon(
                    onPressed: onPause,
                    icon: const Icon(Icons.pause_rounded),
                    label: const Text('PAUSE'),
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFFF59E0B)),
                  ),
                IconButton.filledTonal(
                  onPressed: onStop,
                  icon: const Icon(Icons.stop_rounded, color: Colors.redAccent, size: 20),
                  tooltip: 'Stop Demo',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _speedChip(String label, double val, double currentVal) {
    final selected = (val == currentVal);
    return InkWell(
      onTap: () => onSpeedChanged(val),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF38BDF8) : Colors.white12,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.black : Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  String _formatTime(double seconds) {
    final m = (seconds / 60).floor().toString().padLeft(2, '0');
    final s = (seconds % 60).floor().toString().padLeft(2, '0');
    return '$m:$s';
  }
}
