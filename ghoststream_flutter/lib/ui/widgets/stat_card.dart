import 'package:flutter/material.dart';
import '../../core/theme/ghost_colors.dart';
import '../../core/theme/ghost_theme.dart';

class StatCard extends StatelessWidget {
  final String iconChar;
  final Color iconColor;
  final String label;
  final String value;
  final String? subValue;

  const StatCard({
    super.key,
    required this.iconChar,
    required this.iconColor,
    required this.label,
    required this.value,
    this.subValue,
  });

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: gc.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: gc.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  iconChar,
                  style: TextStyle(fontSize: 11, color: iconColor),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: gc.textTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: ghostMono(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: gc.textPrimary,
            ),
          ),
          if (subValue != null) ...[
            const SizedBox(height: 2),
            Text(
              subValue!,
              style: ghostMono(
                fontSize: 10,
                color: gc.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
