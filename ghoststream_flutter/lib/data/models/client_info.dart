class ClientInfo {
  final String name;
  final String? fingerprint;
  final String? tunAddr;
  final bool enabled;
  final bool connected;
  final int bytesRx;
  final int bytesTx;
  final String? createdAt;
  final int? lastSeenSecs;
  final int? expiresAt;

  const ClientInfo({
    required this.name,
    this.fingerprint,
    this.tunAddr,
    this.enabled = true,
    this.connected = false,
    this.bytesRx = 0,
    this.bytesTx = 0,
    this.createdAt,
    this.lastSeenSecs,
    this.expiresAt,
  });

  factory ClientInfo.fromJson(Map<String, dynamic> json) => ClientInfo(
    name: json['name'] as String? ?? '',
    fingerprint: json['fingerprint'] as String?,
    tunAddr: json['tun_addr'] as String?,
    enabled: json['enabled'] as bool? ?? true,
    connected: json['connected'] as bool? ?? false,
    bytesRx: json['bytes_rx'] as int? ?? 0,
    bytesTx: json['bytes_tx'] as int? ?? 0,
    createdAt: json['created_at'] as String?,
    lastSeenSecs: json['last_seen_secs'] as int?,
    expiresAt: json['expires_at'] as int?,
  );
}

class ServerStatus {
  final int uptime;
  final int activeSessions;
  final String? serverIp;

  const ServerStatus({
    this.uptime = 0,
    this.activeSessions = 0,
    this.serverIp,
  });

  factory ServerStatus.fromJson(Map<String, dynamic> json) => ServerStatus(
    uptime: json['uptime'] as int? ?? 0,
    activeSessions: json['active_sessions'] as int? ?? 0,
    serverIp: json['server_ip'] as String?,
  );
}
