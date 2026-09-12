import 'dart:math';
import 'package:flutter/material.dart';

/// Authentic Google Maps-style navigation vehicle puck with directional chevron.
/// Matches the official Google Maps navigation marker:
/// A crisp white circular disc with drop shadow, containing a vibrant blue
/// navigation arrowhead pointing in the exact direction of travel.
class GoogleMapsPuck extends StatelessWidget {
  /// Heading relative to the screen (0° = straight UP towards top of device).
  final double screenAngleDeg;
  final bool isNavigating;
  final bool isDrMode;
  final double size;

  const GoogleMapsPuck({
    super.key,
    required this.screenAngleDeg,
    this.isNavigating = true,
    this.isDrMode = false,
    this.size = 46.0,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: screenAngleDeg * (pi / 180.0),
      child: Center(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(
              color: const Color(0xFFE2E8F0),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
              BoxShadow(
                color: const Color(0xFF1A73E8).withValues(alpha: 0.15),
                blurRadius: 14,
                spreadRadius: 2,
              ),
            ],
          ),
          child: CustomPaint(
            size: Size(size, size),
            painter: _GoogleArrowPainter(
              color: isDrMode ? const Color(0xFFF59E0B) : const Color(0xFF1A73E8),
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleArrowPainter extends CustomPainter {
  final Color color;

  _GoogleArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width * 0.32;

    final path = Path()
      ..moveTo(cx, cy - r * 1.10) // Top sharp apex
      ..lineTo(cx + r * 0.82, cy + r * 0.85) // Bottom-right corner
      ..lineTo(cx, cy + r * 0.38) // Center inner notch
      ..lineTo(cx - r * 0.82, cy + r * 0.85) // Bottom-left corner
      ..close();

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Soft drop shadow for the arrow inside the white disc
    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.30), 2.0, false);
    canvas.drawPath(path, paint);

    // Crisp outline on arrow for high contrast
    final strokePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.40)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..isAntiAlias = true;
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _GoogleArrowPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
