import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/ghost_colors.dart';
import '../../providers/preferences_provider.dart';
import '../widgets/ghost_overlay.dart';

class RoutesOverlay extends ConsumerStatefulWidget {
  final bool visible;
  final VoidCallback? onDismiss;

  const RoutesOverlay({super.key, required this.visible, this.onDismiss});

  @override
  ConsumerState<RoutesOverlay> createState() => _RoutesOverlayState();
}

class _RoutesOverlayState extends ConsumerState<RoutesOverlay> {
  final _inputCtrl = TextEditingController();
  String _routeMode = 'direct';

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  void _addRule() {
    final value = _inputCtrl.text.trim();
    if (value.isEmpty) return;
    final current = ref.read(preferencesProvider).directCountries;
    final entry = '$_routeMode:$value';
    if (!current.contains(entry)) {
      ref.read(preferencesProvider.notifier).setDirectCountries([...current, entry]);
    }
    _inputCtrl.clear();
  }

  void _removeRule(String rule) {
    final current = ref.read(preferencesProvider).directCountries;
    ref.read(preferencesProvider.notifier).setDirectCountries(current.where((r) => r != rule).toList());
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;
    final prefs = ref.watch(preferencesProvider);
    final splitOn = prefs.splitRouting;
    final rules = prefs.directCountries;

    return GhostOverlay(
      visible: widget.visible,
      onDismiss: widget.onDismiss,
      title: 'Маршрутизация',
      titleColor: gc.yellowWarning,
      titleIcon: Icons.alt_route,
      gradientStart: gc.sheetGradStart,
      gradientEnd: gc.sheetGradEnd,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Раздельная маршрутизация', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: gc.textPrimary)),
                        const SizedBox(height: 3),
                        Text(
                          'Когда включено, адреса из списка можно разруливать отдельно от общего VPN режима.',
                          style: TextStyle(fontSize: 11, color: gc.textTertiary, height: 1.3),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: () => ref.read(preferencesProvider.notifier).setSplit(!splitOn),
                    child: _Toggle(value: splitOn, gc: gc),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _sectionTitle('Активные правила', gc),
            const SizedBox(height: 8),
            if (rules.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('Правил пока нет', style: TextStyle(fontSize: 12, color: gc.textTertiary)),
              )
            else
              ...rules.map((r) {
                final parts = r.split(':');
                final mode = parts.isNotEmpty ? parts[0] : 'direct';
                final value = parts.length > 1 ? parts.sublist(1).join(':') : r;
                final isDirect = mode == 'direct';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 14,
                          color: isDirect ? gc.yellowWarning : gc.accentPurple,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(value, style: GoogleFonts.robotoMono(fontSize: 12, color: gc.textPrimary)),
                              Text(isDirect ? 'напрямую' : 'через VPN', style: TextStyle(fontSize: 10, color: gc.textTertiary)),
                            ],
                          ),
                        ),
                        GestureDetector(
                          onTap: () => _removeRule(r),
                          child: Icon(Icons.close, size: 16, color: gc.dangerRose.withValues(alpha: 0.7)),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            const SizedBox(height: 16),
            _sectionTitle('Добавить правило', gc),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputCtrl,
                    style: TextStyle(fontSize: 13, color: gc.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Например, 192.168.0.0/16',
                      hintStyle: TextStyle(fontSize: 11, color: gc.textTertiary),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: gc.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: gc.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide(color: gc.yellowWarning.withValues(alpha: 0.5)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _addRule,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: gc.yellowWarning.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: gc.yellowWarning.withValues(alpha: 0.3)),
                    ),
                    child: Text('Добавить', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: gc.yellowWarning)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _SegBtn(label: 'Напрямую', active: _routeMode == 'direct', color: gc.yellowWarning, gc: gc, onTap: () => setState(() => _routeMode = 'direct')),
                const SizedBox(width: 6),
                _SegBtn(label: 'Через VPN', active: _routeMode == 'vpn', color: gc.accentPurple, gc: gc, onTap: () => setState(() => _routeMode = 'vpn')),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Поддерживаются домены, отдельные IP и CIDR-сети. Правило будет применено в порядке списка.',
              style: TextStyle(fontSize: 10, color: gc.textTertiary, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, GhostColors gc) {
    return Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: gc.textSecondary));
  }
}

class _SegBtn extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;
  final GhostColors gc;
  final VoidCallback onTap;

  const _SegBtn({required this.label, required this.active, required this.color, required this.gc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: active ? color.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.08)),
        ),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: active ? color : gc.textSecondary)),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final GhostColors gc;

  const _Toggle({required this.value, required this.gc});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 44,
      height: 24,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: value ? gc.greenConnected : Colors.white.withValues(alpha: 0.1),
        border: Border.all(color: value ? gc.greenConnected.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.15)),
      ),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(shape: BoxShape.circle, color: value ? Colors.white : gc.textTertiary),
      ),
    );
  }
}
