import 'package:flutter/material.dart';
import '../../core/theme/ghost_colors.dart';
import '../../core/theme/ghost_theme.dart';

class ServerCard extends StatelessWidget {
  final String flag;
  final String host;
  final String? subscriptionText;
  final VoidCallback? onTap;

  const ServerCard({
    super.key,
    required this.flag,
    required this.host,
    this.subscriptionText,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: gc.card,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: gc.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(flag, style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  host,
                  style: ghostMono(
                    fontSize: 11,
                    color: gc.textSecondary,
                  ),
                ),
                if (subscriptionText != null)
                  Text(
                    subscriptionText!,
                    style: TextStyle(
                      fontSize: 10,
                      color: gc.textTertiary,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
