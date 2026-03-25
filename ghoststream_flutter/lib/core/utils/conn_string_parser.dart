import 'dart:convert';
import 'dart:io';

class ParsedConfig {
  final String addr;
  final String sni;
  final String tun;
  final String cert;
  final String key;
  final String? ca;
  final String? adminUrl;
  final String? adminToken;

  const ParsedConfig({
    required this.addr,
    required this.sni,
    required this.tun,
    required this.cert,
    required this.key,
    this.ca,
    this.adminUrl,
    this.adminToken,
  });
}

class ConnStringParser {
  static ParsedConfig parse(String input) {
    final trimmed = input.trim();
    String jsonStr;

    if (trimmed.startsWith('{')) {
      jsonStr = trimmed;
    } else if (RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(trimmed)) {
      var padded = trimmed;
      while (padded.length % 4 != 0) {
        padded += '=';
      }
      final bytes = base64Url.decode(padded);
      jsonStr = utf8.decode(bytes);
    } else {
      throw FormatException('Unknown format');
    }

    final obj = jsonDecode(jsonStr) as Map<String, dynamic>;
    final admin = obj['admin'] as Map<String, dynamic>?;

    return ParsedConfig(
      addr: obj['addr'] as String,
      sni: obj['sni'] as String,
      tun: obj['tun'] as String,
      cert: obj['cert'] as String,
      key: obj['key'] as String,
      ca: obj['ca'] as String?,
      adminUrl: admin?['url'] as String?,
      adminToken: admin?['token'] as String?,
    );
  }

  static String? build({
    required String serverAddr,
    required String serverName,
    required String tunAddr,
    required String certPath,
    required String keyPath,
    String? caCertPath,
    String? adminUrl,
    String? adminToken,
  }) {
    try {
      final cert = File(certPath).readAsStringSync();
      final key = File(keyPath).readAsStringSync();
      final ca = caCertPath != null ? File(caCertPath).readAsStringSync() : null;

      final json = <String, dynamic>{
        'v': 1,
        'addr': serverAddr,
        'sni': serverName,
        'tun': tunAddr,
        'cert': cert,
        'key': key,
      };
      if (ca != null) json['ca'] = ca;
      if (adminUrl != null && adminToken != null) {
        json['admin'] = {'url': adminUrl, 'token': adminToken};
      }

      return base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    } catch (_) {
      return null;
    }
  }
}
