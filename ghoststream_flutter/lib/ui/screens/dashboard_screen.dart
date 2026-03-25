import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/ghost_colors.dart';
import '../../core/utils/format_utils.dart';
import '../../data/models/vpn_state.dart';
import '../../data/models/vpn_stats.dart';
import '../../providers/dashboard_provider.dart';
import '../../providers/profiles_provider.dart';
import '../../providers/vpn_state_provider.dart';
import '../../providers/vpn_stats_provider.dart';
import '../overlays/add_server_overlay.dart';
import '../overlays/admin_client_overlay.dart';
import '../overlays/admin_overlay.dart';
import '../overlays/apps_overlay.dart';
import '../overlays/dns_overlay.dart';
import '../overlays/logs_overlay.dart';
import '../overlays/routes_overlay.dart';
import '../overlays/settings_overlay.dart';
import '../screens/qr_scanner_screen.dart';
import '../widgets/ghost_mascot.dart';

// ─── Overlay types matching the HTML overlay set ─────────────────────────────

enum _OverlayType {
  none,
  logs,
  settings,
  admin,
  addServer,
  dns,
  apps,
  routes,
  adminClient,
  qrScanner,
}

// ─── Dashboard Screen ────────────────────────────────────────────────────────

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  var _overlay = _OverlayType.none;

  void _toggleVpn(VpnStateType state) {
    switch (state) {
      case VpnStateType.disconnected:
      case VpnStateType.error:
        ref.read(dashboardProvider.notifier).startVpn();
      case VpnStateType.connected:
        ref.read(dashboardProvider.notifier).stopVpn();
      default:
        break;
    }
  }

  void _openOverlay(_OverlayType t) => setState(() => _overlay = t);
  void _closeOverlay() => setState(() => _overlay = _OverlayType.none);

  @override
  Widget build(BuildContext context) {
    final c = context.ghostColors;
    final vpn =
        ref.watch(vpnStateProvider).valueOrNull ?? const VpnState();
    final stats =
        ref.watch(vpnStatsProvider).valueOrNull ?? const VpnStats();
    final dash = ref.watch(dashboardProvider);
    final profile = ref.watch(activeProfileProvider);

    return Scaffold(
      backgroundColor: c.pageBase,
      body: Stack(
        children: [
          // ── Background radial glows ──
          _Background(colors: c),

          // ── Scrollable content ──
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
              physics: const BouncingScrollPhysics(),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  GhostMascot(
                    state: vpn.type,
                    onTap: () => _toggleVpn(vpn.type),
                  ),
                  const SizedBox(height: 4),
                  _ConnectionPill(state: vpn.type),
                  const SizedBox(height: 8),
                  _buildHint(vpn.type, c),
                  const SizedBox(height: 6),
                  _buildTimer(dash.timerText, vpn.type, c),
                  _ServerCard(
                    flag: dash.countryFlag,
                    host: profile?.serverAddr ?? '',
                    subscription: dash.subscriptionText,
                    state: vpn.type,
                  ),
                  const SizedBox(height: 11),
                  _StatsGrid(stats: stats, state: vpn.type),
                  const SizedBox(height: 14),
                  _CubesRow(
                    onLogs: () => _openOverlay(_OverlayType.logs),
                    onSettings: () => _openOverlay(_OverlayType.settings),
                  ),
                  if (dash.error != null) ...[
                    const SizedBox(height: 12),
                    _ErrorBanner(message: dash.error!),
                  ],
                ],
              ),
            ),
          ),

          // ── Overlay layer ──
          LogsOverlay(
            visible: _overlay == _OverlayType.logs,
            onDismiss: _closeOverlay,
          ),
          SettingsOverlay(
            visible: _overlay == _OverlayType.settings,
            onDismiss: _closeOverlay,
            onOpenAddServer: () => _openOverlay(_OverlayType.addServer),
            onOpenDns: () => _openOverlay(_OverlayType.dns),
            onOpenApps: () => _openOverlay(_OverlayType.apps),
            onOpenRoutes: () => _openOverlay(_OverlayType.routes),
            onOpenAdmin: () => _openOverlay(_OverlayType.admin),
            onOpenQrScanner: () => _openOverlay(_OverlayType.qrScanner),
          ),
          AdminOverlay(
            visible: _overlay == _OverlayType.admin,
            onDismiss: _closeOverlay,
            onOpenCreateClient: () => _openOverlay(_OverlayType.adminClient),
          ),
          AddServerOverlay(
            visible: _overlay == _OverlayType.addServer,
            onDismiss: _closeOverlay,
            onOpenQrScanner: () => _openOverlay(_OverlayType.qrScanner),
            onSubmit: (name, connString) {
              ref.read(profilesProvider.notifier).importFromConnString(connString, name: name);
              _closeOverlay();
            },
          ),
          DnsOverlay(
            visible: _overlay == _OverlayType.dns,
            onDismiss: _closeOverlay,
          ),
          AppsOverlay(
            visible: _overlay == _OverlayType.apps,
            onDismiss: _closeOverlay,
          ),
          RoutesOverlay(
            visible: _overlay == _OverlayType.routes,
            onDismiss: _closeOverlay,
          ),
          AdminClientOverlay(
            visible: _overlay == _OverlayType.adminClient,
            onDismiss: _closeOverlay,
          ),
          if (_overlay == _OverlayType.qrScanner)
            Positioned.fill(
              child: QrScannerScreen(
                onResult: (value) {
                  _closeOverlay();
                  ref.read(profilesProvider.notifier).importFromConnString(value);
                },
                onBack: _closeOverlay,
              ),
            ),
        ],
      ),
    );
  }

  // ── Hint ──

  Widget _buildHint(VpnStateType s, GhostColors c) {
    final text = switch (s) {
      VpnStateType.connected => 'Нажми на духа, чтобы отключиться',
      VpnStateType.connecting => 'Устанавливаем соединение…',
      VpnStateType.disconnecting => 'Отключаемся…',
      VpnStateType.error => 'Произошла ошибка',
      _ => 'Нажми на духа, чтобы подключиться',
    };
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        color: c.textTertiary,
        letterSpacing: 0.2,
      ),
    );
  }

  // ── Timer ──

  Widget _buildTimer(String text, VpnStateType s, GhostColors c) {
    final isOff =
        s == VpnStateType.disconnected || s == VpnStateType.error;
    final isMid =
        s == VpnStateType.connecting || s == VpnStateType.disconnecting;

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: AnimatedOpacity(
        opacity: isOff ? 0.42 : (isMid ? 0.72 : 1.0),
        duration: const Duration(milliseconds: 300),
        child: AnimatedScale(
          scale: isMid ? 0.98 : 1.0,
          duration: const Duration(milliseconds: 300),
          child: Text(
            text,
            style: GoogleFonts.robotoMono(
              fontSize: 38,
              fontWeight: FontWeight.w300,
              letterSpacing: 3,
              color: isOff ? c.textSecondary : c.text,
            ),
          ),
        ),
      ),
    );
  }

}

// ─── Background ──────────────────────────────────────────────────────────────

class _Background extends StatelessWidget {
  final GhostColors colors;
  const _Background({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: CustomPaint(painter: _BgPainter(colors)),
    );
  }
}

class _BgPainter extends CustomPainter {
  final GhostColors c;
  const _BgPainter(this.c);

  @override
  void paint(Canvas canvas, Size size) {
    final full = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRect(full, Paint()..color = c.pageBase);

    // Purple glow at the top
    final topGrad = RadialGradient(
      center: const Alignment(0, -1),
      radius: 1.5,
      colors: [c.pageGlowA, c.pageGlowA.withOpacity(0)],
      stops: const [0.0, 0.34],
    );
    canvas.drawRect(full, Paint()..shader = topGrad.createShader(full));

    // Teal glow at the bottom
    final botGrad = RadialGradient(
      center: const Alignment(0, 1),
      radius: 1.2,
      colors: [c.pageGlowB, c.pageGlowB.withOpacity(0)],
      stops: const [0.0, 0.28],
    );
    canvas.drawRect(full, Paint()..shader = botGrad.createShader(full));
  }

  @override
  bool shouldRepaint(_BgPainter old) => !identical(c, old.c);
}

// ─── Connection Pill ─────────────────────────────────────────────────────────

class _ConnectionPill extends StatelessWidget {
  final VpnStateType state;
  const _ConnectionPill({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = context.ghostColors;

    final (bg, border, dotColor, textColor, label) = switch (state) {
      VpnStateType.connected => (
        c.accent2.withOpacity(0.12),
        c.accent2.withOpacity(0.28),
        c.accent2,
        c.accent2,
        'Подключено',
      ),
      VpnStateType.connecting || VpnStateType.disconnecting => (
        c.connectingBlue.withOpacity(0.12),
        c.connectingBlue.withOpacity(0.32),
        c.connectingBlue,
        c.connectingBlue,
        state == VpnStateType.connecting ? 'Подключение…' : 'Отключение…',
      ),
      VpnStateType.error => (
        c.redError.withOpacity(0.12),
        c.redError.withOpacity(0.28),
        c.redError,
        c.redError,
        'Ошибка',
      ),
      _ => (
        Colors.white.withOpacity(0.06),
        Colors.white.withOpacity(0.12),
        c.textTertiary,
        c.textTertiary,
        'Отключено',
      ),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: dotColor,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: textColor,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Server Card ─────────────────────────────────────────────────────────────

class _ServerCard extends StatelessWidget {
  final String? flag;
  final String host;
  final String? subscription;
  final VpnStateType state;

  const _ServerCard({
    required this.flag,
    required this.host,
    required this.subscription,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ghostColors;
    final isOff =
        state == VpnStateType.disconnected || state == VpnStateType.error;

    return AnimatedOpacity(
      opacity: isOff ? 0.55 : 1.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isOff ? Colors.white.withOpacity(0.03) : c.card,
          border: Border.all(color: c.cardBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            if (flag != null) ...[
              Text(flag!, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host.isEmpty ? 'Нет сервера' : host,
                    style: GoogleFonts.robotoMono(
                      fontSize: 11,
                      color: c.textSecondary,
                    ),
                  ),
                  if (subscription != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Подписка: $subscription',
                        style: TextStyle(
                          fontSize: 10,
                          color: c.textTertiary,
                        ),
                      ),
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

// ─── Stats Grid ──────────────────────────────────────────────────────────────

class _StatsGrid extends StatelessWidget {
  final VpnStats stats;
  final VpnStateType state;
  const _StatsGrid({required this.stats, required this.state});

  static String _fmtPkts(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  @override
  Widget build(BuildContext context) {
    final opacity = switch (state) {
      VpnStateType.disconnected || VpnStateType.error => 0.5,
      VpnStateType.connecting || VpnStateType.disconnecting => 0.82,
      _ => 1.0,
    };

    return AnimatedOpacity(
      opacity: opacity,
      duration: const Duration(milliseconds: 300),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Download',
                  icon: '↓',
                  iconBg: const Color.fromRGBO(6, 182, 212, 0.15),
                  iconColor: const Color(0xFF06B6D4),
                  value: formatBytes(stats.bytesRx),
                  sub: 'всего',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: 'Upload',
                  icon: '↑',
                  iconBg: const Color.fromRGBO(139, 92, 246, 0.15),
                  iconColor: const Color(0xFF8B5CF6),
                  value: formatBytes(stats.bytesTx),
                  sub: 'всего',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Session',
                  icon: '⏱',
                  iconBg: const Color.fromRGBO(251, 146, 60, 0.15),
                  iconColor: const Color(0xFFFB923C),
                  value: formatDuration(stats.elapsedSecs),
                  sub: 'время',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: 'Packets',
                  icon: '◈',
                  iconBg: const Color.fromRGBO(34, 211, 160, 0.15),
                  iconColor: const Color(0xFF22D3A0),
                  value: _fmtPkts(stats.pktsRx + stats.pktsTx),
                  sub: 'rx + tx',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String icon;
  final Color iconBg;
  final Color iconColor;
  final String value;
  final String sub;

  const _StatCard({
    required this.label,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ghostColors;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.cardBorder),
        borderRadius: BorderRadius.circular(14),
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
                  color: iconBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                alignment: Alignment.center,
                child: Text(
                  icon,
                  style: TextStyle(fontSize: 11, color: iconColor),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: c.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: GoogleFonts.robotoMono(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: c.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            style: GoogleFonts.robotoMono(
              fontSize: 10,
              color: c.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Cube Buttons ────────────────────────────────────────────────────────────

class _CubesRow extends StatelessWidget {
  final VoidCallback onLogs;
  final VoidCallback onSettings;
  const _CubesRow({required this.onLogs, required this.onSettings});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _CubeButton(
            title: 'Журнал',
            subtitle: 'Системные события',
            icon: Icons.terminal_rounded,
            iconBg: const Color.fromRGBO(96, 165, 250, 0.15),
            iconColor: const Color(0xFF60A5FA),
            onTap: onLogs,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _CubeButton(
            title: 'Параметры',
            subtitle: 'Настройки VPN',
            icon: Icons.tune_rounded,
            iconBg: const Color.fromRGBO(124, 106, 247, 0.15),
            iconColor: const Color(0xFF7C6AF7),
            onTap: onSettings,
          ),
        ),
      ],
    );
  }
}

class _CubeButton extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final VoidCallback onTap;

  const _CubeButton({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.ghostColors;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
        decoration: BoxDecoration(
          color: c.card,
          border: Border.all(color: c.cardBorder),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 20, color: iconColor),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(fontSize: 10, color: c.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Error banner ────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = context.ghostColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: c.redError.withOpacity(0.12),
        border: Border.all(color: c.redError.withOpacity(0.28)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded,
              size: 16, color: c.redError),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11, color: c.redError),
            ),
          ),
        ],
      ),
    );
  }
}
