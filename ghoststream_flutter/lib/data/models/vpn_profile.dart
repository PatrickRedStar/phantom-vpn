class VpnProfile {
  final String id;
  final String name;
  final String serverAddr;
  final String serverName;
  final bool insecure;
  final String certPath;
  final String keyPath;
  final String? caCertPath;
  final String tunAddr;
  final String? adminUrl;
  final String? adminToken;

  const VpnProfile({
    required this.id,
    this.name = 'Подключение',
    this.serverAddr = '',
    this.serverName = '',
    this.insecure = false,
    this.certPath = '',
    this.keyPath = '',
    this.caCertPath,
    this.tunAddr = '10.7.0.2/24',
    this.adminUrl,
    this.adminToken,
  });

  VpnProfile copyWith({
    String? id,
    String? name,
    String? serverAddr,
    String? serverName,
    bool? insecure,
    String? certPath,
    String? keyPath,
    String? caCertPath,
    String? tunAddr,
    String? adminUrl,
    String? adminToken,
  }) {
    return VpnProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      serverAddr: serverAddr ?? this.serverAddr,
      serverName: serverName ?? this.serverName,
      insecure: insecure ?? this.insecure,
      certPath: certPath ?? this.certPath,
      keyPath: keyPath ?? this.keyPath,
      caCertPath: caCertPath ?? this.caCertPath,
      tunAddr: tunAddr ?? this.tunAddr,
      adminUrl: adminUrl ?? this.adminUrl,
      adminToken: adminToken ?? this.adminToken,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'serverAddr': serverAddr,
    'serverName': serverName,
    'insecure': insecure,
    'certPath': certPath,
    'keyPath': keyPath,
    'caCertPath': caCertPath,
    'tunAddr': tunAddr,
    'adminUrl': adminUrl,
    'adminToken': adminToken,
  };

  factory VpnProfile.fromJson(Map<String, dynamic> json) => VpnProfile(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? 'Подключение',
    serverAddr: json['serverAddr'] as String? ?? '',
    serverName: json['serverName'] as String? ?? '',
    insecure: json['insecure'] as bool? ?? false,
    certPath: json['certPath'] as String? ?? '',
    keyPath: json['keyPath'] as String? ?? '',
    caCertPath: json['caCertPath'] as String?,
    tunAddr: json['tunAddr'] as String? ?? '10.7.0.2/24',
    adminUrl: json['adminUrl'] as String?,
    adminToken: json['adminToken'] as String?,
  );
}
