import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../data/models/vpn_state.dart';
import '../data/models/vpn_stats.dart';
import '../core/utils/format_utils.dart';
import 'vpn_state_provider.dart';
import 'vpn_stats_provider.dart';
import 'profiles_provider.dart';
import 'preferences_provider.dart';

class DashboardState {
  final VpnState vpnState;
  final VpnStats stats;
  final String timerText;
  final String? subscriptionText;
  final String? countryFlag;
  final String? error;

  const DashboardState({
    this.vpnState = const VpnState(),
    this.stats = const VpnStats(),
    this.timerText = '00:00:00',
    this.subscriptionText,
    this.countryFlag,
    this.error,
  });

  DashboardState copyWith({
    VpnState? vpnState,
    VpnStats? stats,
    String? timerText,
    String? subscriptionText,
    String? countryFlag,
    String? error,
  }) =>
      DashboardState(
        vpnState: vpnState ?? this.vpnState,
        stats: stats ?? this.stats,
        timerText: timerText ?? this.timerText,
        subscriptionText: subscriptionText ?? this.subscriptionText,
        countryFlag: countryFlag ?? this.countryFlag,
        error: error,
      );
}

String? _countryFlag(String? serverName) {
  if (serverName == null || serverName.isEmpty) return null;
  final parts = serverName.split('.');
  if (parts.length < 2) return null;
  final tld = parts.last.toLowerCase();
  const tldToFlag = {
    'ru': '\u{1F1F7}\u{1F1FA}',
    'de': '\u{1F1E9}\u{1F1EA}',
    'nl': '\u{1F1F3}\u{1F1F1}',
    'fi': '\u{1F1EB}\u{1F1EE}',
    'us': '\u{1F1FA}\u{1F1F8}',
    'uk': '\u{1F1EC}\u{1F1E7}',
    'fr': '\u{1F1EB}\u{1F1F7}',
    'jp': '\u{1F1EF}\u{1F1F5}',
    'sg': '\u{1F1F8}\u{1F1EC}',
    'ca': '\u{1F1E8}\u{1F1E6}',
  };
  return tldToFlag[tld];
}

Future<String?> _fetchSubscription(String adminUrl, String adminToken, String tunAddr) async {
  try {
    final base = adminUrl.endsWith('/') ? adminUrl.substring(0, adminUrl.length - 1) : adminUrl;
    final resp = await http.get(
      Uri.parse('$base/api/clients'),
      headers: {'Authorization': 'Bearer $adminToken'},
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;

    final clients = jsonDecode(resp.body) as List;
    final tunPrefix = tunAddr.split('/').first;

    for (final c in clients) {
      final map = c as Map<String, dynamic>;
      final addr = (map['tun_addr'] as String? ?? '').split('/').first;
      if (addr == tunPrefix) {
        final expiresAt = map['expires_at'] as int?;
        if (expiresAt == null) return 'Бессрочно';
        final expiry = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
        final diff = expiry.difference(DateTime.now());
        if (diff.isNegative) return 'Истекла';
        if (diff.inDays > 0) return '${diff.inDays} дн.';
        return '${diff.inHours} ч.';
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

class DashboardNotifier extends StateNotifier<DashboardState> {
  final Ref _ref;

  DashboardNotifier(this._ref) : super(const DashboardState()) {
    _ref.listen<AsyncValue<VpnState>>(vpnStateProvider, (_, next) {
      final s = next.valueOrNull ?? const VpnState();
      state = state.copyWith(vpnState: s);
      if (s.isConnected) _refreshSubscription();
    });
    _ref.listen<AsyncValue<VpnStats>>(vpnStatsProvider, (_, next) {
      final s = next.valueOrNull ?? const VpnStats();
      state = state.copyWith(
        stats: s,
        timerText: formatDuration(s.elapsedSecs),
      );
    });
    final profile = _ref.read(activeProfileProvider);
    state = state.copyWith(countryFlag: _countryFlag(profile?.serverName));
  }

  void _refreshSubscription() {
    final profile = _ref.read(activeProfileProvider);
    if (profile?.adminUrl == null || profile?.adminToken == null) return;
    _fetchSubscription(profile!.adminUrl!, profile.adminToken!, profile.tunAddr)
        .then((text) {
      if (mounted) state = state.copyWith(subscriptionText: text);
    });
  }

  Future<void> startVpn() async {
    final profile = _ref.read(activeProfileProvider);
    if (profile == null) {
      state = state.copyWith(error: 'Нет активного профиля');
      return;
    }
    final bridge = _ref.read(vpnBridgeProvider);
    try {
      state = state.copyWith(error: null);
      final config = _ref.read(prefsRepoProvider).buildConfig(
            serverAddr: profile.serverAddr,
            serverName: profile.serverName,
            certPath: profile.certPath,
            keyPath: profile.keyPath,
            caCertPath: profile.caCertPath,
            tunAddr: profile.tunAddr,
          );
      final result = await bridge.startVpn(
        serverAddr: config.serverAddr,
        serverName: config.serverName,
        insecure: config.insecure,
        certPath: config.certPath,
        keyPath: config.keyPath,
        caCertPath: config.caCertPath ?? '',
        tunAddr: config.tunAddr,
        dnsServers: config.dnsServers.join(','),
        splitRouting: config.splitRouting,
        perAppMode: config.perAppMode,
        perAppList: config.perAppList.join(','),
      );
      if (result != 0) {
        state = state.copyWith(error: 'Ошибка запуска VPN ($result)');
      }
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> stopVpn() async {
    try {
      await _ref.read(vpnBridgeProvider).stopVpn();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }
}

final dashboardProvider = StateNotifierProvider<DashboardNotifier, DashboardState>((ref) {
  return DashboardNotifier(ref);
});
