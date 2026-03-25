import 'dart:convert';

enum VpnStateType { disconnected, connecting, connected, error, disconnecting }

class VpnState {
  final VpnStateType type;
  final String? message;
  final String? serverName;

  const VpnState({
    this.type = VpnStateType.disconnected,
    this.message,
    this.serverName,
  });

  bool get isConnected => type == VpnStateType.connected;
  bool get isConnecting => type == VpnStateType.connecting;
  bool get isDisconnected => type == VpnStateType.disconnected;
  bool get isError => type == VpnStateType.error;

  factory VpnState.fromJson(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final state = json['state'] as String? ?? 'disconnected';
    return VpnState(
      type: VpnStateType.values.firstWhere(
        (e) => e.name == state,
        orElse: () => VpnStateType.disconnected,
      ),
      message: json['message'] as String?,
      serverName: json['serverName'] as String?,
    );
  }
}
