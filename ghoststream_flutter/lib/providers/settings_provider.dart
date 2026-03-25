import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repositories/routing_rules_repository.dart';
import '../data/services/vpn_service_bridge.dart';
import 'vpn_state_provider.dart';
import 'profiles_provider.dart';

final routingRulesRepoProvider = Provider<RoutingRulesRepository>((ref) {
  return RoutingRulesRepository();
});

class SettingsState {
  final Map<String, int?> pingResults;
  final bool pinging;
  final String? importStatus;
  final List<AppInfo> installedApps;
  final bool loadingApps;
  final Map<String, bool> downloadingRules;
  final List<RuleInfo> downloadedRules;
  final String? error;

  const SettingsState({
    this.pingResults = const {},
    this.pinging = false,
    this.importStatus,
    this.installedApps = const [],
    this.loadingApps = false,
    this.downloadingRules = const {},
    this.downloadedRules = const [],
    this.error,
  });

  SettingsState copyWith({
    Map<String, int?>? pingResults,
    bool? pinging,
    String? importStatus,
    List<AppInfo>? installedApps,
    bool? loadingApps,
    Map<String, bool>? downloadingRules,
    List<RuleInfo>? downloadedRules,
    String? error,
  }) =>
      SettingsState(
        pingResults: pingResults ?? this.pingResults,
        pinging: pinging ?? this.pinging,
        importStatus: importStatus ?? this.importStatus,
        installedApps: installedApps ?? this.installedApps,
        loadingApps: loadingApps ?? this.loadingApps,
        downloadingRules: downloadingRules ?? this.downloadingRules,
        downloadedRules: downloadedRules ?? this.downloadedRules,
        error: error,
      );
}

class SettingsNotifier extends StateNotifier<SettingsState> {
  final Ref _ref;

  SettingsNotifier(this._ref) : super(const SettingsState());

  Future<void> pingProfile(String profileId, String serverAddr) async {
    final parts = serverAddr.split(':');
    if (parts.length != 2) return;
    final host = parts[0];
    final port = int.tryParse(parts[1]);
    if (port == null) return;

    try {
      final sw = Stopwatch()..start();
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      sw.stop();
      socket.destroy();
      final updated = Map<String, int?>.from(state.pingResults);
      updated[profileId] = sw.elapsedMilliseconds;
      state = state.copyWith(pingResults: updated);
    } catch (_) {
      final updated = Map<String, int?>.from(state.pingResults);
      updated[profileId] = null;
      state = state.copyWith(pingResults: updated);
    }
  }

  Future<void> pingAll() async {
    final profiles = _ref.read(profilesProvider).profiles;
    state = state.copyWith(pinging: true);
    final futures = profiles.map((p) => pingProfile(p.id, p.serverAddr));
    await Future.wait(futures);
    if (mounted) state = state.copyWith(pinging: false);
  }

  Future<void> loadInstalledApps() async {
    state = state.copyWith(loadingApps: true);
    try {
      final apps = await _ref.read(vpnBridgeProvider).getInstalledApps();
      if (mounted) state = state.copyWith(installedApps: apps, loadingApps: false);
    } catch (e) {
      if (mounted) state = state.copyWith(loadingApps: false, error: e.toString());
    }
  }

  Future<void> downloadRules(String code) async {
    final updated = Map<String, bool>.from(state.downloadingRules);
    updated[code] = true;
    state = state.copyWith(downloadingRules: updated);
    try {
      await _ref.read(routingRulesRepoProvider).downloadRuleList(code);
      await refreshDownloadedRules();
    } catch (e) {
      if (mounted) state = state.copyWith(error: e.toString());
    } finally {
      if (mounted) {
        final done = Map<String, bool>.from(state.downloadingRules);
        done.remove(code);
        state = state.copyWith(downloadingRules: done);
      }
    }
  }

  Future<void> deleteRules(String code) async {
    await _ref.read(routingRulesRepoProvider).deleteRuleList(code);
    await refreshDownloadedRules();
  }

  Future<void> refreshDownloadedRules() async {
    final rules = await _ref.read(routingRulesRepoProvider).getDownloadedRules();
    if (mounted) state = state.copyWith(downloadedRules: rules);
  }

  void setImportStatus(String? status) {
    state = state.copyWith(importStatus: status);
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier(ref);
});
