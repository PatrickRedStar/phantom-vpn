import 'package:flutter/material.dart';
import '../../core/theme/ghost_colors.dart';

class GhostOverlay extends StatelessWidget {
  final bool visible;
  final VoidCallback? onDismiss;
  final String title;
  final Color? titleColor;
  final Object? titleIcon;
  final Color? gradientStart;
  final Color? gradientEnd;
  final Object? actions;
  final double maxWidth;
  final Widget child;

  const GhostOverlay({
    super.key,
    required this.visible,
    this.onDismiss,
    required this.title,
    this.titleColor,
    this.titleIcon,
    this.gradientStart,
    this.gradientEnd,
    this.actions,
    this.maxWidth = 324,
    required this.child,
  });

  Widget? _resolveIcon(Object? icon, Color fallbackColor) {
    if (icon == null) return null;
    if (icon is Widget) return icon;
    if (icon is IconData) return Icon(icon, size: 18, color: fallbackColor);
    return null;
  }

  Widget? _resolveActions(Object? a) {
    if (a == null) return null;
    if (a is Widget) return a;
    if (a is List<Widget>) {
      return Row(mainAxisSize: MainAxisSize.min, children: a);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();

    final gc = context.ghostColors;
    final start = gradientStart ?? gc.sheetGradStart;
    final end = gradientEnd ?? gc.sheetGradEnd;
    final tColor = titleColor ?? gc.textPrimary;
    final screenH = MediaQuery.of(context).size.height;
    final resolvedIcon = _resolveIcon(titleIcon, tColor);
    final resolvedActions = _resolveActions(actions);

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss ?? () {},
            child: ColoredBox(color: gc.overlayBackdrop),
          ),
        ),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: screenH * 0.82,
              ),
              child: Material(
                color: Colors.transparent,
                child: GestureDetector(
                  onTap: () {},
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 280),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [start, end],
                      ),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: gc.shadowColor,
                          blurRadius: 60,
                          offset: const Offset(0, 30),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
                          child: Row(
                            children: [
                              Expanded(
                                child: Row(
                                  children: [
                                    if (resolvedIcon != null) ...[
                                      resolvedIcon,
                                      const SizedBox(width: 8),
                                    ],
                                    Flexible(
                                      child: Text(
                                        title,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: tColor,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (resolvedActions != null) ...[
                                const SizedBox(width: 8),
                                resolvedActions,
                                const SizedBox(width: 8),
                              ],
                              _CloseButton(
                                onTap: onDismiss ?? () {},
                                color: gc.textSecondary,
                              ),
                            ],
                          ),
                        ),
                        Flexible(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(16, 0, 16, 18),
                            child: child,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  final Color color;

  const _CloseButton({required this.onTap, required this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.08),
        ),
        alignment: Alignment.center,
        child: Text(
          '✕',
          style: TextStyle(fontSize: 13, color: color),
        ),
      ),
    );
  }
}
