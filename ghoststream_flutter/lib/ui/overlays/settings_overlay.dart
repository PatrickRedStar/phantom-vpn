import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants.dart';
import '../../core/theme/ghost_colors.dart';
import '../../data/models/vpn_profile.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/profiles_provider.dart';
import '../../providers/settings_provider.dart';
import '../widgets/ghost_overlay.dart';

class SettingsOverlay extends ConsumerWidget {
  final bool visible;
  final VoidCallback? onDismiss;
  final VoidCallback? onOpenAddServer;
  final VoidCallback? onOpenDns;
  final VoidCallback? onOpenApps;
  final VoidCallback? onOpenRoutes;
  final VoidCallback? onOpenAdmin;
  final VoidCallback? onOpenQrScanner;
  final VoidCallback? onShareDebug;

  const SettingsOverlay({
    super.key,
    required this.visible,
    this.onDismiss,
    this.onOpenAddServer,
    this.onOpenDns,
    this.onOpenApps,
    this.onOpenRoutes,
    this.onOpenAdmin,
    this.onOpenQrScanner,
    this.onShareDebug,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gc = context.ghostColors;
    final profilesState = ref.watch(profilesProvider);
    final prefs = ref.watch(preferencesProvider);
    final settings = ref.watch(settingsProvider);

    return GhostOverlay(
      visible: visible,
      onDismiss: onDismiss,
      title: 'Параметры',
      titleColor: gc.accentPurple,
      titleIcon: Icons.settings,
      gradientStart: gc.settSheetGradStart,
      gradientEnd: gc.settSheetGradEnd,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildConnectionsSection(context, ref, gc, profilesState, settings),
            const SizedBox(height: 16),
            _buildDnsSection(gc, prefs),
            const SizedBox(height: 16),
            _buildNetworkSection(ref, gc, prefs),
            const SizedBox(height: 16),
            _buildRoutingSection(gc, prefs),
            const SizedBox(height: 16),
            _buildThemeSection(ref, gc, prefs),
            const SizedBox(height: 16),
            _buildSupportSection(gc),
            const SizedBox(height: 16),
            _buildAboutSection(gc),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionsSection(
    BuildContext context,
    WidgetRef ref,
    GhostColors gc,
    ProfilesState profilesState,
    SettingsState settings,
  ) {
    final profiles = profilesState.profiles;
    final activeId = profilesState.activeId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: 'Подключения', gc: gc),
        const SizedBox(height: 8),
        if (profiles.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
            decoration: _cardDecoration(gc),
            child: Text(
              'Подключений пока нет. Добавьте новый хост или отсканируйте QR-код.',
              style: TextStyle(fontSize: 12, color: gc.textTertiary),
            ),
          )
        else
          Container(
            decoration: _cardDecoration(gc),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                ...profiles.map((p) => _ProfileRow(
                      profile: p,
                      isActive: p.id == activeId || (activeId == null && p == profiles.first),
                      ping: settings.pingResults[p.id],
                      gc: gc,
                      onSelect: () => ref.read(profilesProvider.notifier).setActiveId(p.id),
                    )),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(
                    children: [
                      _IconAct(
                        icon: Icons.qr_code_scanner,
                        color: gc.accentPurple,
                        onTap: onOpenQrScanner,
                      ),
                      const SizedBox(width: 6),
                      if (_activeHasAdmin(profiles, activeId))
                        _IconAct(
                          icon: Icons.shield_outlined,
                          color: gc.accentPurple,
                          onTap: onOpenAdmin,
                        ),
                      if (_activeHasAdmin(profiles, activeId)) const SizedBox(width: 6),
                      _IconAct(
                        icon: Icons.delete_outline,
                        color: gc.dangerRose,
                        onTap: () {
                          final target = activeId ?? profiles.first.id;
                          ref.read(profilesProvider.notifier).deleteProfile(target);
                        },
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, thickness: 1, color: Color.fromRGBO(255, 255, 255, 0.06)),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: onOpenAddServer,
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: gc.accentPurple.withValues(alpha: 0.3),
                                style: BorderStyle.solid,
                              ),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              'Подключение',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.accentPurple),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => ref.read(settingsProvider.notifier).pingAll(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: gc.accentPurple.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: gc.accentPurple.withValues(alpha: 0.3)),
                            ),
                            alignment: Alignment.center,
                            child: settings.pinging
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 1.5, color: gc.accentPurple),
                                  )
                                : Text(
                                    '↺ Ping все',
                                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.accentPurple),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  bool _activeHasAdmin(List<VpnProfile> profiles, String? activeId) {
    final p = activeId != null ? profiles.where((x) => x.id == activeId).firstOrNull : profiles.firstOrNull;
    return p?.adminUrl != null && p!.adminUrl!.isNotEmpty;
  }

  Widget _buildDnsSection(GhostColors gc, PreferencesState prefs) {
    final servers = prefs.dnsServers;
    final activePreset = _activePreset(servers);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: 'DNS серверы', gc: gc),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: _cardDecoration(gc),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Кастомный DNS стек',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: gc.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${servers.length} сервера · системный резолв',
                          style: TextStyle(fontSize: 11, color: gc.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: gc.accentTeal.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'DNS',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: gc.accentTeal),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: dnsPresets.keys.map((name) {
                  final active = activePreset == name;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? gc.accentTeal.withValues(alpha: 0.14) : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: active ? gc.accentTeal.withValues(alpha: 0.35) : Colors.white.withValues(alpha: 0.07),
                      ),
                    ),
                    child: Text(
                      name,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: active ? gc.accentTeal : gc.textSecondary,
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: onOpenDns,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Настроить DNS',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.textSecondary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String? _activePreset(List<String> servers) {
    for (final entry in dnsPresets.entries) {
      if (entry.value.length == servers.length && entry.value.every(servers.contains)) {
        return entry.key;
      }
    }
    return null;
  }

  Widget _buildNetworkSection(WidgetRef ref, GhostColors gc, PreferencesState prefs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: 'Сеть', gc: gc),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: _cardDecoration(gc),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Не проверять сертификат',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: gc.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Только при ручной настройке без CA',
                      style: TextStyle(fontSize: 11, color: gc.textTertiary),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => ref.read(preferencesProvider.notifier).setInsecure(!prefs.insecure),
                child: _GhostToggle(value: prefs.insecure, gc: gc),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRoutingSection(GhostColors gc, PreferencesState prefs) {
    final splitOn = prefs.splitRouting;
    final rulesCount = prefs.directCountries.length;
    final perAppMode = prefs.perAppMode;

    String appModeLabel;
    String appModeBadge;
    String appModeNote;
    switch (perAppMode) {
      case 'exclude':
        appModeLabel = 'Исключения';
        appModeBadge = 'BYPASS';
        appModeNote = 'Выбранные приложения идут мимо VPN напрямую.';
        break;
      case 'include':
        appModeLabel = 'Только выбранные';
        appModeBadge = 'ONLY';
        appModeNote = 'Через VPN идут только указанные приложения.';
        break;
      default:
        appModeLabel = 'Полный туннель';
        appModeBadge = 'FULL';
        appModeNote = 'Список приложений и поиск открываются отдельно, чтобы настройки не разрастались.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: 'Маршрутизация трафика', gc: gc),
        const SizedBox(height: 8),
        Container(
          decoration: _cardDecoration(gc),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Правила адресов и сетей',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: gc.textPrimary),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '$rulesCount правил · ${splitOn ? "direct/vpn mix" : "всё через VPN"}',
                                style: TextStyle(fontSize: 11, color: gc.textTertiary),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: (splitOn ? gc.yellowWarning : gc.textTertiary).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            splitOn ? 'SPLIT ON' : 'SPLIT OFF',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: splitOn ? gc.yellowWarning : gc.textTertiary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Все ручные маршруты спрятаны в отдельном редакторе. Здесь только краткий статус.',
                      style: TextStyle(fontSize: 10, color: gc.textTertiary, height: 1.3),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: onOpenRoutes,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Настроить маршруты',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.textSecondary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Маршрутизация приложений',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: gc.textPrimary),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                perAppMode == 'none' ? 'Все приложения идут через VPN' : appModeLabel,
                                style: TextStyle(fontSize: 11, color: gc.textTertiary),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: gc.accentPurple.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            appModeBadge,
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: gc.accentPurple),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(appModeLabel, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                      appModeNote,
                      style: TextStyle(fontSize: 10, color: gc.textTertiary, height: 1.3),
                    ),
                    const SizedBox(height: 8),
                    GestureDetector(
                      onTap: onOpenApps,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          'Настроить приложения',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.textSecondary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildThemeSection(WidgetRef ref, GhostColors gc, PreferencesState prefs) {
    const modes = [
      ('dark', 'Тёмная'),
      ('light', 'Светлая'),
      ('system', 'Авто'),
    ];
    final currentTheme = prefs.theme;
    String noteText;
    switch (currentTheme) {
      case 'dark':
        noteText = 'Текущий режим: тёмная тема.';
        break;
      case 'light':
        noteText = 'Текущий режим: светлая тема.';
        break;
      default:
        noteText = 'Текущий режим: следует за системой.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: 'Оформление', gc: gc),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: _cardDecoration(gc),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: modes.map((m) {
                  final active = currentTheme == m.$1;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: m.$1 != 'system' ? 6 : 0),
                      child: GestureDetector(
                        onTap: () => ref.read(preferencesProvider.notifier).setTheme(m.$1),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          decoration: BoxDecoration(
                            color: active ? gc.accentPurple.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: active ? gc.accentPurple.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.06),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            m.$2,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: active ? gc.accentPurple : gc.textSecondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 8),
              Text(
                noteText,
                style: TextStyle(fontSize: 10, color: gc.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSupportSection(GhostColors gc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: 'Поддержка', gc: gc),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: onShareDebug,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: gc.greenConnected.withValues(alpha: 0.35)),
              color: gc.greenConnected.withValues(alpha: 0.06),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bug_report_outlined, size: 16, color: gc.greenConnected),
                const SizedBox(width: 8),
                Text(
                  'Поделиться отладочной информацией',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: gc.greenConnected),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAboutSection(GhostColors gc) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(text: 'О приложении', gc: gc),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: _cardDecoration(gc),
          child: Row(
            children: [
              const Text('👻', style: TextStyle(fontSize: 24)),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'GhostStream VPN',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: gc.textPrimary),
                  ),
                  Text(
                    'v$appVersion · QUIC / Noise Protocol',
                    style: TextStyle(fontSize: 11, color: gc.textTertiary),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  BoxDecoration _cardDecoration(GhostColors gc) {
    return BoxDecoration(
      color: gc.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: gc.border),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final GhostColors gc;

  const _SectionLabel({required this.text, required this.gc});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: gc.textSecondary),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  final VpnProfile profile;
  final bool isActive;
  final int? ping;
  final GhostColors gc;
  final VoidCallback onSelect;

  const _ProfileRow({
    required this.profile,
    required this.isActive,
    required this.ping,
    required this.gc,
    required this.onSelect,
  });

  String? _flagForAddr(String serverAddr) {
    final host = serverAddr.split(':').first.toLowerCase();
    for (final entry in countryFlags.entries) {
      if (host.contains(entry.key.toLowerCase())) return entry.value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final flag = _flagForAddr(profile.serverAddr);

    Color pingColor;
    if (ping == null) {
      pingColor = gc.textTertiary;
    } else if (ping! < 100) {
      pingColor = gc.pingGood;
    } else if (ping! < 300) {
      pingColor = gc.pingMid;
    } else {
      pingColor = gc.pingHigh;
    }

    return GestureDetector(
      onTap: onSelect,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isActive ? gc.accentPurple : gc.textTertiary,
                  width: 2,
                ),
                color: isActive ? gc.accentPurple : Colors.transparent,
              ),
              child: isActive
                  ? Center(
                      child: Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white,
                        ),
                      ),
                    )
                  : null,
            ),
            if (flag != null) ...[
              const SizedBox(width: 10),
              Text(flag, style: const TextStyle(fontSize: 18)),
            ],
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          profile.name,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: gc.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (ping != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: pingColor.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 5,
                                height: 5,
                                decoration: BoxDecoration(shape: BoxShape.circle, color: pingColor),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${ping}ms',
                                style: GoogleFonts.robotoMono(fontSize: 10, fontWeight: FontWeight.w500, color: pingColor),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profile.serverAddr,
                    style: TextStyle(fontSize: 11, color: gc.textTertiary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconAct extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _IconAct({required this.icon, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}

class _GhostToggle extends StatelessWidget {
  final bool value;
  final GhostColors gc;

  const _GhostToggle({required this.value, required this.gc});

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
        border: Border.all(
          color: value ? gc.greenConnected.withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.15),
        ),
      ),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: value ? Colors.white : gc.textTertiary,
        ),
      ),
    );
  }
}
