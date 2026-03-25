import 'dart:convert';

class VpnStats {
  final int bytesRx;
  final int bytesTx;
  final int pktsRx;
  final int pktsTx;
  final bool connected;
  final int elapsedSecs;

  const VpnStats({
    this.bytesRx = 0,
    this.bytesTx = 0,
    this.pktsRx = 0,
    this.pktsTx = 0,
    this.connected = false,
    this.elapsedSecs = 0,
  });

  factory VpnStats.fromJson(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return VpnStats(
      bytesRx: (json['bytes_rx'] ?? json['bytesRx'] ?? 0) as int,
      bytesTx: (json['bytes_tx'] ?? json['bytesTx'] ?? 0) as int,
      pktsRx: (json['pkts_rx'] ?? json['pktsRx'] ?? 0) as int,
      pktsTx: (json['pkts_tx'] ?? json['pktsTx'] ?? 0) as int,
      connected: (json['connected'] ?? false) as bool,
      elapsedSecs: (json['elapsed_secs'] ?? json['elapsedSecs'] ?? 0) as int,
    );
  }
}
