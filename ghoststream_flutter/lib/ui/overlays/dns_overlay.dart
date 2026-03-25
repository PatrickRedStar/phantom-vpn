import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants.dart';
import '../../core/theme/ghost_colors.dart';
import '../../providers/preferences_provider.dart';
import '../widgets/ghost_overlay.dart';

class DnsOverlay extends ConsumerStatefulWidget {
  final bool visible;
  final VoidCallback? onDismiss;

  const DnsOverlay({super.key, required this.visible, this.onDismiss});

  @override
  ConsumerState<DnsOverlay> createState() => _DnsOverlayState();
}

class _DnsOverlayState extends ConsumerState<DnsOverlay> {
  final _inputCtrl = TextEditingController();

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  void _addServer() {
    final value = _inputCtrl.text.trim();
    if (value.isEmpty) return;
    final current = ref.read(preferencesProvider).dnsServers;
    if (!current.contains(value)) {
      ref.read(preferencesProvider.notifier).setDns([...current, value]);
    }
    _inputCtrl.clear();
  }

  void _removeServer(String server) {
    final current = ref.read(preferencesProvider).dnsServers;
    ref.read(preferencesProvider.notifier).setDns(current.where((s) => s != server).toList());
  }

  void _applyPreset(String name) {
    final servers = dnsPresets[name];
    if (servers != null) {
      ref.read(preferencesProvider.notifier).setDns(servers);
    }
  }

  bool _isPresetActive(List<String> current, String name) {
    final preset = dnsPresets[name];
    if (preset == null) return false;
    return preset.length == current.length && preset.every(current.contains);
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;
    final prefs = ref.watch(preferencesProvider);
    final servers = prefs.dnsServers;

    return GhostOverlay(
      visible: widget.visible,
      onDismiss: widget.onDismiss,
      title: 'DNS стек',
      titleColor: gc.accentTeal,
      titleIcon: Icons.gps_fixed,
      gradientStart: gc.sheetGradStart,
      gradientEnd: gc.sheetGradEnd,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _sectionTitle('Активные DNS', gc),
            const SizedBox(height: 8),
            if (servers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Нет серверов', style: TextStyle(fontSize: 11, color: gc.textTertiary)),
              )
            else
              ...servers.map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        color: Colors.white.withValues(alpha: 0.03),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              s,
                              style: GoogleFonts.robotoMono(fontSize: 12, color: gc.textPrimary),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _removeServer(s),
                            child: Icon(Icons.close, size: 14, color: gc.dangerRose.withValues(alpha: 0.7)),
                          ),
                        ],
                      ),
                    ),
                  )),
            const SizedBox(height: 14),
            _sectionTitle('Добавить сервер', gc),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    style: TextStyle(fontSize: 12, color: gc.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Например, 9.9.9.9 или dns.google',
                      hintStyle: TextStyle(fontSize: 11, color: gc.textTertiary),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.04),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: gc.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: gc.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: gc.accentTeal.withValues(alpha: 0.5)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _addServer,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: gc.accentTeal.withValues(alpha: 0.3)),
                      color: gc.accentTeal.withValues(alpha: 0.12),
                    ),
                    child: Text(
                      'Добавить',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: gc.accentTeal),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Поддерживаются обычные IP, домены DNS-over-HTTPS и резервные резолверы.',
              style: TextStyle(fontSize: 10, color: gc.textTertiary, height: 1.4),
            ),
            const SizedBox(height: 14),
            _sectionTitle('Быстрые пресеты', gc),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: dnsPresets.keys.map((name) {
                final active = _isPresetActive(servers, name);
                return GestureDetector(
                  onTap: () => _applyPreset(name),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? gc.accentTeal.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.08),
                      ),
                      color: active ? gc.accentTeal.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.04),
                    ),
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: active ? gc.accentTeal : gc.textSecondary,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, GhostColors gc) {
    return Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: gc.textSecondary),
    );
  }
}
