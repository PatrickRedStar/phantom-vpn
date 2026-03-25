import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/ghost_colors.dart';
import '../../data/models/log_entry.dart';
import '../../providers/vpn_logs_provider.dart';
import '../widgets/ghost_overlay.dart';

class LogsOverlay extends ConsumerWidget {
  final bool visible;
  final VoidCallback? onDismiss;

  const LogsOverlay({super.key, required this.visible, this.onDismiss});

  static const _filters = ['ALL', 'TRACE', 'DEBUG', 'INFO', 'WARN'];

  Color _levelColor(String level, GhostColors gc) {
    switch (level.toLowerCase()) {
      case 'error':
        return gc.redError;
      case 'warn':
      case 'warning':
        return gc.yellowWarning;
      case 'debug':
        return gc.blueDebug;
      case 'trace':
        return gc.textTertiary;
      default:
        return gc.blueDebug;
    }
  }

  String _logsAsText(List<LogEntry> logs) {
    return logs
        .map((e) => '${e.timestamp} [${e.level.toUpperCase()}] ${e.message}')
        .join('\n');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gc = context.ghostColors;
    final state = ref.watch(logsProvider);
    final logs = state.filteredLogs;
    final currentFilter = state.filterLevel;

    return GhostOverlay(
      visible: visible,
      onDismiss: onDismiss,
      title: 'Логи',
      titleColor: gc.connectingBlue,
      titleIcon: Icons.article_outlined,
      gradientStart: gc.logsSheetGradStart,
      gradientEnd: gc.logsSheetGradEnd,
      actions: [
        _MiniButton(
          color: gc.dangerRose,
          icon: Icons.delete_outline,
          onTap: () => ref.read(logsProvider.notifier).clear(),
        ),
        const SizedBox(width: 6),
        _MiniButton(
          color: gc.connectingBlue,
          icon: Icons.copy,
          onTap: () {
            final text = _logsAsText(logs);
            if (text.isNotEmpty) Clipboard.setData(ClipboardData(text: text));
          },
        ),
        const SizedBox(width: 6),
        _MiniButton(
          color: gc.greenConnected,
          icon: Icons.share,
          onTap: () {
            final text = _logsAsText(logs);
            if (text.isNotEmpty) {
              Share.share(text);
            }
          },
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 5),
              itemBuilder: (context, i) {
                final f = _filters[i];
                final isActive = (f == 'ALL' && currentFilter == 'all') ||
                    f.toLowerCase() == currentFilter;
                return GestureDetector(
                  onTap: () =>
                      ref.read(logsProvider.notifier).setFilter(f.toLowerCase()),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isActive
                            ? gc.connectingBlue.withValues(alpha: 0.5)
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                      color: isActive
                          ? gc.connectingBlue.withValues(alpha: 0.12)
                          : Colors.transparent,
                    ),
                    child: Text(
                      f,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        color: isActive ? gc.connectingBlue : gc.textTertiary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: logs.isEmpty
                ? Center(
                    child: Text(
                      'Нет записей',
                      style: TextStyle(fontSize: 12, color: gc.textTertiary),
                    ),
                  )
                : ListView.builder(
                    itemCount: logs.length,
                    itemBuilder: (context, i) {
                      final log = logs[logs.length - 1 - i];
                      final mono = GoogleFonts.robotoMono(fontSize: 10, height: 1.6);
                      return Container(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.white.withValues(alpha: 0.03),
                            ),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 60,
                              child: Text(
                                log.timestamp.length > 8
                                    ? log.timestamp.substring(log.timestamp.length - 8)
                                    : log.timestamp,
                                style: mono.copyWith(color: gc.textTertiary),
                              ),
                            ),
                            const SizedBox(width: 6),
                            SizedBox(
                              width: 38,
                              child: Text(
                                log.level.toUpperCase(),
                                style: mono.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: _levelColor(log.level, gc),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                log.message,
                                style: mono.copyWith(color: gc.textSecondary),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final Color color;
  final IconData icon;
  final VoidCallback? onTap;

  const _MiniButton({required this.color, required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.14),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 15, color: color),
      ),
    );
  }
}
