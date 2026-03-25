class VpnConfig {
  final String serverAddr;
  final String serverName;
  final bool insecure;
  final String certPath;
  final String keyPath;
  final String? caCertPath;
  final String tunAddr;
  final List<String> dnsServers;
  final bool splitRouting;
  final List<String> directCountries;
  final String perAppMode;
  final List<String> perAppList;

  const VpnConfig({
    this.serverAddr = '',
    this.serverName = '',
    this.insecure = false,
    this.certPath = '',
    this.keyPath = '',
    this.caCertPath,
    this.tunAddr = '10.7.0.2/24',
    this.dnsServers = const ['8.8.8.8', '1.1.1.1'],
    this.splitRouting = false,
    this.directCountries = const [],
    this.perAppMode = 'none',
    this.perAppList = const [],
  });

  VpnConfig copyWith({
    String? serverAddr,
    String? serverName,
    bool? insecure,
    String? certPath,
    String? keyPath,
    String? caCertPath,
    String? tunAddr,
    List<String>? dnsServers,
    bool? splitRouting,
    List<String>? directCountries,
    String? perAppMode,
    List<String>? perAppList,
  }) {
    return VpnConfig(
      serverAddr: serverAddr ?? this.serverAddr,
      serverName: serverName ?? this.serverName,
      insecure: insecure ?? this.insecure,
      certPath: certPath ?? this.certPath,
      keyPath: keyPath ?? this.keyPath,
      caCertPath: caCertPath ?? this.caCertPath,
      tunAddr: tunAddr ?? this.tunAddr,
      dnsServers: dnsServers ?? this.dnsServers,
      splitRouting: splitRouting ?? this.splitRouting,
      directCountries: directCountries ?? this.directCountries,
      perAppMode: perAppMode ?? this.perAppMode,
      perAppList: perAppList ?? this.perAppList,
    );
  }
}
