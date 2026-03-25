import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/client_info.dart';
import '../data/services/admin_api_service.dart';

class AdminState {
  final ServerStatus? serverStatus;
  final List<ClientInfo> clients;
  final bool loading;
  final String? error;
  final String? lastConnString;

  const AdminState({
    this.serverStatus,
    this.clients = const [],
    this.loading = false,
    this.error,
    this.lastConnString,
  });

  AdminState copyWith({
    ServerStatus? serverStatus,
    List<ClientInfo>? clients,
    bool? loading,
    String? error,
    String? lastConnString,
  }) =>
      AdminState(
        serverStatus: serverStatus ?? this.serverStatus,
        clients: clients ?? this.clients,
        loading: loading ?? this.loading,
        error: error,
        lastConnString: lastConnString,
      );
}

class AdminNotifier extends StateNotifier<AdminState> {
  AdminApiService? _api;

  AdminNotifier() : super(const AdminState());

  bool get hasApi => _api != null;

  void init(String url, String token) {
    _api = AdminApiService(baseUrl: url, token: token);
    refresh();
  }

  Future<void> refresh() async {
    if (_api == null) return;
    state = state.copyWith(loading: true, error: null);
    try {
      final results = await Future.wait([
        _api!.getStatus(),
        _api!.getClients(),
      ]);
      if (mounted) {
        state = state.copyWith(
          serverStatus: results[0] as ServerStatus,
          clients: results[1] as List<ClientInfo>,
          loading: false,
        );
      }
    } catch (e) {
      if (mounted) state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> createClient(String name, {int? expiresDays}) async {
    if (_api == null) return;
    state = state.copyWith(loading: true, error: null);
    try {
      await _api!.createClient(name, expiresDays: expiresDays);
      await refresh();
    } catch (e) {
      if (mounted) state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> deleteClient(String name) async {
    if (_api == null) return;
    state = state.copyWith(loading: true, error: null);
    try {
      await _api!.deleteClient(name);
      await refresh();
    } catch (e) {
      if (mounted) state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> toggleEnabled(String name, bool enable) async {
    if (_api == null) return;
    try {
      await _api!.toggleEnabled(name, enable);
      await refresh();
    } catch (e) {
      if (mounted) state = state.copyWith(error: e.toString());
    }
  }

  Future<void> getConnString(String name) async {
    if (_api == null) return;
    try {
      final cs = await _api!.getConnString(name);
      if (mounted) state = state.copyWith(lastConnString: cs);
    } catch (e) {
      if (mounted) state = state.copyWith(error: e.toString());
    }
  }

  Future<void> manageSubscription(String name, String action, {int? days}) async {
    if (_api == null) return;
    state = state.copyWith(loading: true, error: null);
    try {
      await _api!.manageSubscription(name, action, days: days);
      await refresh();
    } catch (e) {
      if (mounted) state = state.copyWith(loading: false, error: e.toString());
    }
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}

final adminProvider = StateNotifierProvider<AdminNotifier, AdminState>((ref) {
  return AdminNotifier();
});
