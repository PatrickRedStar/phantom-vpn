import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';

class MiniToast extends StatefulWidget {
  final String message;
  final bool visible;
  final bool danger;
  final VoidCallback? onDismissed;

  const MiniToast({
    super.key,
    required this.message,
    this.visible = false,
    this.danger = false,
    this.onDismissed,
  });

  @override
  State<MiniToast> createState() => _MiniToastState();
}

class _MiniToastState extends State<MiniToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _fadeAnim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slideAnim = Tween(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

    if (widget.visible) _ctrl.forward();
  }

  @override
  void didUpdateWidget(MiniToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) {
      _ctrl.forward();
    } else if (!widget.visible && oldWidget.visible) {
      _ctrl.reverse().then((_) => widget.onDismissed?.call());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;
    final borderColor = widget.danger
        ? gc.dangerRose.withValues(alpha: 0.3)
        : gc.border;
    final textColor = widget.danger ? gc.dangerRose : gc.textPrimary;

    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: gc.miniToastBg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: gc.shadowColor,
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Text(
            widget.message,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}

class MiniToastOverlay extends StatelessWidget {
  final String message;
  final bool visible;
  final bool danger;
  final VoidCallback? onDismissed;

  const MiniToastOverlay({
    super.key,
    required this.message,
    this.visible = false,
    this.danger = false,
    this.onDismissed,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 32,
      left: 0,
      right: 0,
      child: Center(
        child: MiniToast(
          message: message,
          visible: visible,
          danger: danger,
          onDismissed: onDismissed,
        ),
      ),
    );
  }
}
