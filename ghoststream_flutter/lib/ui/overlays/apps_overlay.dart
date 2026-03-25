import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/ghost_colors.dart';
import '../../data/services/vpn_service_bridge.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/settings_provider.dart';
import '../widgets/ghost_overlay.dart';

class AppsOverlay extends ConsumerStatefulWidget {
  final bool visible;
  final VoidCallback? onDismiss;

  const AppsOverlay({super.key, required this.visible, this.onDismiss});

  @override
  ConsumerState<AppsOverlay> createState() => _AppsOverlayState();
}

class _AppsOverlayState extends ConsumerState<AppsOverlay> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  static const _modes = [
    ('none', 'Все через VPN', 'Никаких исключений. Устройство полностью в туннеле.'),
    ('exclude', 'Все, кроме выбранных', 'Локальные сервисы и банковские приложения можно вывести напрямую.'),
    ('include', 'Только выбранные', 'Подходит для selective routing и тестовых сценариев.'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(settingsProvider.notifier).loadInstalledApps();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;
    final prefs = ref.watch(preferencesProvider);
    final settings = ref.watch(settingsProvider);
    final currentMode = prefs.perAppMode;
    final selectedApps = prefs.perAppList;

    final apps = _query.isEmpty
        ? <AppInfo>[]
        : settings.installedApps.where((a) {
            final q = _query.toLowerCase();
            return a.label.toLowerCase().contains(q) || a.packageName.toLowerCase().contains(q);
          }).toList();

    return GhostOverlay(
      visible: widget.visible,
      onDismiss: widget.onDismiss,
      title: 'Приложения',
      titleColor: gc.accentPurple,
      titleIcon: Icons.apps,
      gradientStart: gc.settSheetGradStart,
      gradientEnd: gc.settSheetGradEnd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _sectionTitle('Режим маршрутизации', gc),
          const SizedBox(height: 8),
          ..._modes.map((m) {
            final active = currentMode == m.$1;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: GestureDetector(
                onTap: () => ref.read(preferencesProvider.notifier).setPerAppMode(m.$1),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: active ? gc.accentPurple.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: active ? gc.accentPurple.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.07),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.$2,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: active ? gc.accentPurple : gc.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(m.$3, style: TextStyle(fontSize: 11, color: gc.textTertiary, height: 1.3)),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 14),
          _sectionTitle('Поиск приложений', gc),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(Icons.search, size: 18, color: gc.textTertiary),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(fontSize: 13, color: gc.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Начни вводить название приложения',
                      hintStyle: TextStyle(fontSize: 12, color: gc.textTertiary),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (settings.loadingApps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: gc.accentPurple),
                ),
              ),
            )
          else if (_query.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Показываются только релевантные приложения по твоему запросу.',
                style: TextStyle(fontSize: 11, color: gc.textTertiary),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: apps.length,
                itemBuilder: (context, i) {
                  final app = apps[i];
                  final selected = selectedApps.contains(app.packageName);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: GestureDetector(
                      onTap: () => ref.read(preferencesProvider.notifier).togglePerApp(app.packageName),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: selected ? gc.accentPurple.withValues(alpha: 0.1) : Colors.white.withValues(alpha: 0.03),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected ? gc.accentPurple.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.06),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.android, size: 20, color: selected ? gc.accentPurple : gc.textTertiary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(app.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.textPrimary), maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text(app.packageName, style: TextStyle(fontSize: 10, color: gc.textTertiary), maxLines: 1, overflow: TextOverflow.ellipsis),
                                ],
                              ),
                            ),
                            _Toggle(value: selected, activeColor: gc.accentPurple, gc: gc),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, GhostColors gc) {
    return Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: gc.textSecondary));
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final Color activeColor;
  final GhostColors gc;

  const _Toggle({required this.value, required this.activeColor, required this.gc});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 40,
      height: 22,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: value ? activeColor : Colors.white.withValues(alpha: 0.1),
        border: Border.all(color: value ? activeColor.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.15)),
      ),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(shape: BoxShape.circle, color: value ? Colors.white : gc.textTertiary),
      ),
    );
  }
}
