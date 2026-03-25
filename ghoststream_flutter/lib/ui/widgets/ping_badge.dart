import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';

enum PingState { good, mid, high, loading }

class PingBadge extends StatefulWidget {
  final int? pingMs;
  final bool isLoading;

  const PingBadge({
    super.key,
    this.pingMs,
    this.isLoading = false,
  });

  @override
  State<PingBadge> createState() => _PingBadgeState();
}

class _PingBadgeState extends State<PingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _pulseAnim = Tween(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );
    if (widget.isLoading) _pulseCtrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(PingBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading && !_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat(reverse: true);
    } else if (!widget.isLoading && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
      _pulseCtrl.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    super.dispose();
  }

  PingState get _state {
    if (widget.isLoading) return PingState.loading;
    final ms = widget.pingMs;
    if (ms == null) return PingState.loading;
    if (ms <= 70) return PingState.good;
    if (ms <= 140) return PingState.mid;
    return PingState.high;
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    final color = switch (_state) {
      PingState.good => gc.pingGood,
      PingState.mid => gc.pingMid,
      PingState.high => gc.pingHigh,
      PingState.loading => gc.connectingBlue,
    };

    final label = widget.isLoading || widget.pingMs == null
        ? '...'
        : '${widget.pingMs} ms';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnim,
            builder: (_, __) => Opacity(
              opacity: widget.isLoading ? _pulseAnim.value : 1.0,
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color,
                ),
              ),
            ),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
