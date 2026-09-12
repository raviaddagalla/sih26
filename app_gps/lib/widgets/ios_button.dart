import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Premium iOS-native tactile button with spring-scale micro-interaction,
/// frosted glass background, subtle highlight borders, and haptic feedback.
class IosGlassButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final Widget? icon;
  final String label;
  final Color? backgroundColor;
  final Color foregroundColor;
  final double height;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final bool isDestructive;

  const IosGlassButton({
    super.key,
    required this.onPressed,
    this.icon,
    required this.label,
    this.backgroundColor,
    this.foregroundColor = Colors.white,
    this.height = 50.0,
    this.padding = const EdgeInsets.symmetric(horizontal: 20),
    this.borderRadius = 16.0,
    this.isDestructive = false,
  });

  @override
  State<IosGlassButton> createState() => _IosGlassButtonState();
}

class _IosGlassButtonState extends State<IosGlassButton> with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      reverseDuration: const Duration(milliseconds: 180),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (widget.onPressed == null) return;
    HapticFeedback.lightImpact();
    _anim.forward();
  }

  void _onTapUp(TapUpDetails _) {
    if (widget.onPressed == null) return;
    _anim.reverse();
    widget.onPressed?.call();
  }

  void _onTapCancel() {
    _anim.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveBg = widget.isDestructive
        ? const Color(0xFFE5484D).withValues(alpha: 0.85)
        : (widget.backgroundColor ?? const Color(0xFF007AFF).withValues(alpha: 0.88));

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) => Transform.scale(
          scale: _scale.value,
          child: child,
        ),
        child: Container(
          height: widget.height,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: effectiveBg,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.18),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                widget.icon!,
                const SizedBox(width: 10),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  color: widget.foregroundColor,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Circular or rounded-square frosted glass icon button with haptic feedback
class IosIconButton extends StatefulWidget {
  final VoidCallback? onPressed;
  final IconData icon;
  final Color? color;
  final Color? backgroundColor;
  final Color? iconColor;
  final Color? foregroundColor;
  final double size;
  final double? iconSize;
  final String? tooltip;

  const IosIconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.color,
    this.backgroundColor,
    this.iconColor,
    this.foregroundColor,
    this.size = 46.0,
    this.iconSize,
    this.tooltip,
  });

  @override
  State<IosIconButton> createState() => _IosIconButtonState();
}

class _IosIconButtonState extends State<IosIconButton> with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) {
    if (widget.onPressed == null) return;
    HapticFeedback.selectionClick();
    _anim.forward();
  }

  void _onTapUp(TapUpDetails _) {
    if (widget.onPressed == null) return;
    _anim.reverse();
    widget.onPressed?.call();
  }

  void _onTapCancel() {
    _anim.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final effectiveBg = widget.backgroundColor ??
        widget.color ??
        const Color(0xFF0F172A).withValues(alpha: 0.65);
    final effectiveIconColor =
        widget.foregroundColor ?? widget.iconColor ?? Colors.white;
    final effectiveIconSize = widget.iconSize ?? (widget.size * 0.48);

    final btn = GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) => Transform.scale(
          scale: _scale.value,
          child: child,
        ),
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: effectiveBg,
            shape: BoxShape.circle,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.16),
              width: 0.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 14,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Center(
            child: Icon(
              widget.icon,
              color: effectiveIconColor,
              size: effectiveIconSize,
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip!, child: btn);
    }
    return btn;
  }
}
