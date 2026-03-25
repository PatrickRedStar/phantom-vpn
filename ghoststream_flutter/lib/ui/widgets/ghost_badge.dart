import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';

enum GhostBadgeVariant { accent, alt, warn }

class GhostBadge extends StatelessWidget {
  final String text;
  final GhostBadgeVariant variant;

  const GhostBadge({
    super.key,
    required this.text,
    this.variant = GhostBadgeVariant.accent,
  });

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    final (Color fg, Color bg, Color borderColor) = switch (variant) {
      GhostBadgeVariant.accent => (
          gc.accentPurple,
          gc.accentPurple.withValues(alpha: 0.1),
          gc.accentPurple.withValues(alpha: 0.24),
        ),
      GhostBadgeVariant.alt => (
          gc.accentTeal,
          gc.accentTeal.withValues(alpha: 0.1),
          gc.accentTeal.withValues(alpha: 0.24),
        ),
      GhostBadgeVariant.warn => (
          gc.yellowWarning,
          gc.yellowWarning.withValues(alpha: 0.1),
          gc.yellowWarning.withValues(alpha: 0.24),
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: 0.3,
          height: 1,
        ),
      ),
    );
  }
}
