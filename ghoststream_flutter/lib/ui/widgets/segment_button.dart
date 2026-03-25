import 'package:flutter/material.dart';

import '../../core/theme/ghost_colors.dart';

class SegmentButton<T> extends StatelessWidget {
  final List<SegmentItem<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  const SegmentButton({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: segments.map((seg) {
          final isActive = seg.value == selected;
          return Padding(
            padding: const EdgeInsets.only(right: 5),
            child: GestureDetector(
              onTap: () => onChanged(seg.value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: isActive
                      ? gc.accentPurple.withValues(alpha: 0.12)
                      : Colors.transparent,
                  border: Border.all(
                    color: isActive
                        ? gc.accentPurple.withValues(alpha: 0.5)
                        : gc.border,
                  ),
                ),
                child: Text(
                  seg.label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    color: isActive ? gc.accentPurple : gc.textTertiary,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class SegmentItem<T> {
  final T value;
  final String label;

  const SegmentItem({required this.value, required this.label});
}
