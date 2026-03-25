import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/vpn_state.dart';
import '../models/vpn_stats.dart';
import '../models/log_entry.dart';

class VpnServiceBridge {
  static const _method = MethodChannel('ghoststream/vpn');
  static const _stateEvent = EventChannel('ghoststream/vpn_state');
  static const _statsEvent = EventChannel('ghoststream/vpn_stats');
  static const _logsEvent = EventChannel('ghoststream/vpn_logs');

  Stream<VpnState>? _stateStream;
  Stream<VpnStats>? _statsStream;
  Stream<List<LogEntry>>? _logsStream;

  Stream<VpnState> get stateStream {
    _stateStream ??= _stateEvent
        .receiveBroadcastStream()
        .map((raw) => VpnState.fromJson(raw as String))
        .handleError((_) {});
    return _stateStream!;
  }

  Stream<VpnStats> get statsStream {
    _statsStream ??= _statsEvent
        .receiveBroadcastStream()
        .map((raw) => VpnStats.fromJson(raw as String))
        .handleError((_) {});
    return _statsStream!;
  }

  Stream<List<LogEntry>> get logsStream {
    _logsStream ??= _logsEvent
        .receiveBroadcastStream()
        .map((raw) {
          final list = jsonDecode(raw as String) as List;
          return list
              .map((e) => LogEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        })
        .handleError((_) {});
    return _logsStream!;
  }

  Future<int> startVpn({
    required String serverAddr,
    required String serverName,
    required bool insecure,
    required String certPath,
    required String keyPath,
    String caCertPath = '',
    String tunAddr = '10.7.0.2/24',
    String dnsServers = '8.8.8.8,1.1.1.1',
    bool splitRouting = false,
    String directCidrsPath = '',
    String perAppMode = 'none',
    String perAppList = '',
  }) async {
    final result = await _method.invokeMethod<int>('startVpn', {
      'serverAddr': serverAddr,
      'serverName': serverName,
      'insecure': insecure,
      'certPath': certPath,
      'keyPath': keyPath,
      'caCertPath': caCertPath,
      'tunAddr': tunAddr,
      'dnsServers': dnsServers,
      'splitRouting': splitRouting,
      'directCidrsPath': directCidrsPath,
      'perAppMode': perAppMode,
      'perAppList': perAppList,
    });
    return result ?? -1;
  }

  Future<void> stopVpn() async {
    await _method.invokeMethod('stopVpn');
  }

  Future<void> setLogLevel(String level) async {
    await _method.invokeMethod('setLogLevel', {'level': level});
  }

  Future<String?> computeVpnRoutes(String path) async {
    return await _method.invokeMethod<String>('computeVpnRoutes', {'path': path});
  }

  Future<bool> prepareVpn() async {
    return await _method.invokeMethod<bool>('prepareVpn') ?? false;
  }

  Future<List<AppInfo>> getInstalledApps() async {
    final raw = await _method.invokeMethod<String>('getInstalledApps');
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => AppInfo.fromJson(e as Map<String, dynamic>)).toList();
  }
}

class AppInfo {
  final String packageName;
  final String label;
  final bool isSystem;

  const AppInfo({
    required this.packageName,
    required this.label,
    this.isSystem = false,
  });

  factory AppInfo.fromJson(Map<String, dynamic> json) => AppInfo(
    packageName: json['packageName'] as String? ?? '',
    label: json['label'] as String? ?? '',
    isSystem: json['isSystem'] as bool? ?? false,
  );
}
