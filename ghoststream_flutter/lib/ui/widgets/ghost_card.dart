import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';

class GhostCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final VoidCallback? onTap;

  const GhostCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = 14,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    final card = Container(
      decoration: BoxDecoration(
        color: gc.card,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: gc.border),
      ),
      padding: padding,
      child: child,
    );

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: card);
    }
    return card;
  }
}
