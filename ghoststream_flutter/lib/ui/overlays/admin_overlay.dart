import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/ghost_colors.dart';
import '../../core/utils/format_utils.dart';
import '../../data/models/client_info.dart';
import '../../providers/admin_provider.dart';
import '../../providers/profiles_provider.dart';
import '../widgets/ghost_overlay.dart';

class AdminOverlay extends ConsumerStatefulWidget {
  final bool visible;
  final VoidCallback? onDismiss;
  final VoidCallback? onOpenCreateClient;

  const AdminOverlay({
    super.key,
    required this.visible,
    this.onDismiss,
    this.onOpenCreateClient,
  });

  @override
  ConsumerState<AdminOverlay> createState() => _AdminOverlayState();
}

class _AdminOverlayState extends ConsumerState<AdminOverlay> {
  String _search = '';
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final profile = ref.read(activeProfileProvider);
      if (profile?.adminUrl != null && profile?.adminToken != null) {
        final notifier = ref.read(adminProvider.notifier);
        if (!notifier.hasApi) {
          notifier.init(profile!.adminUrl!, profile.adminToken!);
        }
      }
    });
  }

  List<ClientInfo> _filteredClients(List<ClientInfo> all) {
    var result = all;
    if (_filter == 'online') {
      result = result.where((c) => c.connected).toList();
    } else if (_filter == 'offline') {
      result = result.where((c) => !c.connected).toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      result = result
          .where((c) =>
              c.name.toLowerCase().contains(q) ||
              (c.tunAddr?.toLowerCase().contains(q) ?? false))
          .toList();
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;
    final admin = ref.watch(adminProvider);
    final profile = ref.watch(activeProfileProvider);
    final clients = _filteredClients(admin.clients);

    return GhostOverlay(
      visible: widget.visible,
      onDismiss: widget.onDismiss,
      title: 'Администрирование',
      titleIcon: Icons.shield_outlined,
      gradientStart: gc.adminSheetGradStart,
      gradientEnd: gc.adminSheetGradEnd,
      maxWidth: 340,
      actions: [
        GestureDetector(
          onTap: () => ref.read(adminProvider.notifier).refresh(),
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.08),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            alignment: Alignment.center,
            child: admin.loading
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: gc.textSecondary,
                    ),
                  )
                : Text('↻', style: TextStyle(fontSize: 15, color: gc.textSecondary)),
          ),
        ),
      ],
      child: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 70),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AdminHero(
                  gc: gc,
                  status: admin.serverStatus,
                  serverAlias: profile?.name ?? '',
                  serverAddr: profile?.serverAddr ?? '',
                  serverIp: admin.serverStatus?.serverIp,
                ),
                const SizedBox(height: 12),
                _KpiRow(gc: gc, status: admin.serverStatus),
                const SizedBox(height: 12),
                _ClientsCard(
                  gc: gc,
                  clients: clients,
                  totalCount: admin.clients.length,
                  search: _search,
                  filter: _filter,
                  loading: admin.loading,
                  onSearchChanged: (v) => setState(() => _search = v),
                  onFilterChanged: (v) => setState(() => _filter = v),
                  onToggle: (name, enable) =>
                      ref.read(adminProvider.notifier).toggleEnabled(name, enable),
                  onDelete: (name) =>
                      ref.read(adminProvider.notifier).deleteClient(name),
                ),
              ],
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              onTap: widget.onOpenCreateClient,
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [gc.accentPurple, gc.accentPurpleLight],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: gc.accentPurple.withValues(alpha: 0.45),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.person_add, size: 22, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdminHero extends StatelessWidget {
  final GhostColors gc;
  final ServerStatus? status;
  final String serverAlias;
  final String serverAddr;
  final String? serverIp;

  const _AdminHero({
    required this.gc,
    required this.status,
    required this.serverAlias,
    required this.serverAddr,
    required this.serverIp,
  });

  @override
  Widget build(BuildContext context) {
    final hasActive = (status?.activeSessions ?? 0) > 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: const Alignment(-0.6, -1),
          end: const Alignment(0.6, 1),
          colors: [
            gc.accentPurple.withValues(alpha: 0.28),
            gc.accentPurple.withValues(alpha: 0.12),
            gc.accentPurple.withValues(alpha: 0.06),
          ],
        ),
        border: Border.all(color: gc.accentPurple.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 30,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'HOST CONTROL ROOM',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: gc.textTertiary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      serverAlias.isNotEmpty ? serverAlias : 'Server',
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: gc.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  color: (hasActive ? gc.greenConnected : gc.textTertiary).withValues(alpha: 0.14),
                  border: Border.all(
                    color: (hasActive ? gc.greenConnected : gc.textTertiary).withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: hasActive ? gc.greenConnected : gc.textTertiary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      hasActive ? 'Сессии активны' : 'Нет сессий',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: hasActive ? gc.greenConnected : gc.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.only(top: 12),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Входная точка',
                        style: TextStyle(fontSize: 9, color: gc.textTertiary),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        serverAddr,
                        style: GoogleFonts.robotoMono(fontSize: 11, color: gc.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        'Выходной IP',
                        style: TextStyle(fontSize: 9, color: gc.textTertiary),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        serverIp ?? '—',
                        style: GoogleFonts.robotoMono(fontSize: 11, color: gc.textPrimary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiRow extends StatelessWidget {
  final GhostColors gc;
  final ServerStatus? status;

  const _KpiRow({required this.gc, required this.status});

  @override
  Widget build(BuildContext context) {
    final uptime = status?.uptime ?? 0;
    final uptimeText = uptime >= 3600 ? '${uptime ~/ 3600} ч' : '${uptime ~/ 60} м';

    return Row(
      children: [
        _KpiCard(gc: gc, label: 'Аптайм', value: uptimeText, sub: 'без деградации'),
        const SizedBox(width: 6),
        _KpiCard(gc: gc, label: 'Сессии', value: '${status?.activeSessions ?? 0}', sub: 'активно сейчас'),
        const SizedBox(width: 6),
        _KpiCard(gc: gc, label: 'Транспорт', value: 'QUIC', sub: 'ghost tunnel'),
      ],
    );
  }
}

class _KpiCard extends StatelessWidget {
  final GhostColors gc;
  final String label;
  final String value;
  final String sub;

  const _KpiCard({
    required this.gc,
    required this.label,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.white.withValues(alpha: 0.04),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 9, letterSpacing: 0.8, color: gc.textTertiary),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: GoogleFonts.robotoMono(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: gc.textPrimary,
              ),
            ),
            const SizedBox(height: 3),
            Text(sub, style: TextStyle(fontSize: 9, color: gc.textTertiary)),
          ],
        ),
      ),
    );
  }
}

class _ClientsCard extends StatelessWidget {
  final GhostColors gc;
  final List<ClientInfo> clients;
  final int totalCount;
  final String search;
  final String filter;
  final bool loading;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onFilterChanged;
  final void Function(String, bool) onToggle;
  final ValueChanged<String> onDelete;

  const _ClientsCard({
    required this.gc,
    required this.clients,
    required this.totalCount,
    required this.search,
    required this.filter,
    required this.loading,
    required this.onSearchChanged,
    required this.onFilterChanged,
    required this.onToggle,
    required this.onDelete,
  });

  static const _filters = [
    ('all', 'Все'),
    ('online', 'Онлайн'),
    ('offline', 'Отключены'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Клиенты',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: gc.textPrimary),
              ),
              Text('$totalCount устройств', style: TextStyle(fontSize: 11, color: gc.textTertiary)),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withValues(alpha: 0.04),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 10),
                Icon(Icons.search, size: 16, color: gc.textTertiary),
                Expanded(
                  child: TextField(
                    onChanged: onSearchChanged,
                    style: TextStyle(fontSize: 12, color: gc.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Поиск клиента или IP',
                      hintStyle: TextStyle(fontSize: 11, color: gc.textTertiary),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            children: _filters.map((f) {
              final active = filter == f.$1;
              return GestureDetector(
                onTap: () => onFilterChanged(f.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: active ? gc.accentPurple.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: active ? gc.accentPurple.withValues(alpha: 0.4) : Colors.white.withValues(alpha: 0.06),
                    ),
                  ),
                  child: Text(
                    f.$2,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: active ? gc.accentPurple : gc.textSecondary,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 10),
          if (loading && clients.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else if (clients.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text('Нет клиентов', style: TextStyle(fontSize: 12, color: gc.textTertiary)),
              ),
            )
          else
            ...clients.map((c) => _ClientRow(
                  gc: gc,
                  client: c,
                  onToggle: () => onToggle(c.name, !c.enabled),
                  onDelete: () => onDelete(c.name),
                )),
        ],
      ),
    );
  }
}

class _ClientRow extends StatelessWidget {
  final GhostColors gc;
  final ClientInfo client;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _ClientRow({
    required this.gc,
    required this.client,
    required this.onToggle,
    required this.onDelete,
  });

  String _subscriptionTag() {
    if (client.expiresAt == null) return '∞';
    final expiry = DateTime.fromMillisecondsSinceEpoch(client.expiresAt! * 1000);
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return 'Истекла';
    if (diff.inDays > 0) return '${diff.inDays}д';
    return '${diff.inHours}ч';
  }

  Color _subscriptionColor() {
    if (client.expiresAt == null) return gc.textTertiary;
    final expiry = DateTime.fromMillisecondsSinceEpoch(client.expiresAt! * 1000);
    final diff = expiry.difference(DateTime.now());
    if (diff.isNegative) return gc.redError;
    if (diff.inDays < 7) return gc.yellowWarning;
    return gc.greenConnected;
  }

  @override
  Widget build(BuildContext context) {
    final subTag = _subscriptionTag();
    final subColor = _subscriptionColor();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: client.connected ? gc.greenConnected : Colors.transparent,
                border: Border.all(
                  color: client.connected
                      ? gc.greenConnected.withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.3),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          client.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: gc.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: subColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          subTag,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: subColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${client.tunAddr ?? '-'} · ↓${formatBytes(client.bytesRx)} ↑${formatBytes(client.bytesTx)}',
                    style: GoogleFonts.robotoMono(fontSize: 10, color: gc.textTertiary),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: onToggle,
              child: Icon(
                client.enabled ? Icons.pause_circle_outline : Icons.play_circle_outline,
                size: 18,
                color: client.enabled ? gc.yellowWarning : gc.greenConnected,
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onDelete,
              child: Icon(
                Icons.delete_outline,
                size: 18,
                color: gc.dangerRose.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
