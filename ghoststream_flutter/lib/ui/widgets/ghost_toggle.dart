import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';

class GhostToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const GhostToggle({
    super.key,
    required this.value,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return GestureDetector(
      onTap: onChanged != null ? () => onChanged!(!value) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        width: 40,
        height: 22,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(11),
          color: value
              ? gc.accentPurple.withValues(alpha: 0.4)
              : Colors.white.withValues(alpha: 0.1),
          border: Border.all(
            color: value
                ? gc.accentPurple.withValues(alpha: 0.5)
                : gc.border,
          ),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}
