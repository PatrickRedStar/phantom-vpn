import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';

enum VpnConnectionState { connected, connecting, disconnected, error }

class ConnectionPill extends StatefulWidget {
  final VpnConnectionState state;
  final VoidCallback? onTap;

  const ConnectionPill({
    super.key,
    required this.state,
    this.onTap,
  });

  @override
  State<ConnectionPill> createState() => _ConnectionPillState();
}

class _ConnectionPillState extends State<ConnectionPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );
    _updateAnimation();
  }

  @override
  void didUpdateWidget(ConnectionPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.state == VpnConnectionState.connected ||
        widget.state == VpnConnectionState.connecting) {
      _pulseCtrl.repeat();
    } else {
      _pulseCtrl.stop();
      _pulseCtrl.value = 0;
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    final (Color dotColor, Color bgColor, Color borderColor, String label) =
        switch (widget.state) {
      VpnConnectionState.connected => (
          gc.greenConnected,
          gc.greenConnected.withValues(alpha: 0.12),
          gc.greenConnected.withValues(alpha: 0.28),
          'Подключён',
        ),
      VpnConnectionState.connecting => (
          gc.connectingBlue,
          gc.connectingBlue.withValues(alpha: 0.12),
          gc.connectingBlue.withValues(alpha: 0.32),
          'Подключение...',
        ),
      VpnConnectionState.disconnected => (
          gc.textTertiary,
          Colors.white.withValues(alpha: 0.06),
          Colors.white.withValues(alpha: 0.12),
          'Выключен',
        ),
      VpnConnectionState.error => (
          gc.redError,
          gc.redError.withValues(alpha: 0.12),
          gc.redError.withValues(alpha: 0.28),
          'Ошибка',
        ),
    };

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PulseDot(
              color: dotColor,
              animation: _pulseCtrl,
              shouldPulse: widget.state == VpnConnectionState.connected ||
                  widget.state == VpnConnectionState.connecting,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: dotColor,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PulseDot extends AnimatedWidget {
  final Color color;
  final bool shouldPulse;

  const _PulseDot({
    required this.color,
    required Animation<double> animation,
    required this.shouldPulse,
  }) : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    final ctrl = listenable as AnimationController;
    final pulseValue = shouldPulse
        ? (1.0 - ctrl.value) * 8.0
        : 0.0;
    final pulseOpacity = shouldPulse
        ? (1.0 - ctrl.value) * 0.42
        : 0.0;

    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: shouldPulse
            ? [
                BoxShadow(
                  color: color.withValues(alpha: pulseOpacity),
                  blurRadius: 0,
                  spreadRadius: pulseValue,
                ),
              ]
            : null,
      ),
    );
  }
}
