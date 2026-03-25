import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_config.dart';

class PreferencesRepository {
  static const _kDns = 'dns_servers';
  static const _kSplit = 'split_routing';
  static const _kCountries = 'direct_countries';
  static const _kPerAppMode = 'per_app_mode';
  static const _kPerAppList = 'per_app_list';
  static const _kTheme = 'theme';
  static const _kInsecure = 'insecure';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String get theme => _prefs.getString(_kTheme) ?? 'system';
  Future<void> setTheme(String value) => _prefs.setString(_kTheme, value);

  List<String> get dnsServers {
    final raw = _prefs.getString(_kDns);
    if (raw == null || raw.isEmpty) return ['8.8.8.8', '1.1.1.1'];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  Future<void> setDnsServers(List<String> servers) =>
      _prefs.setString(_kDns, servers.join(','));

  bool get splitRouting => _prefs.getBool(_kSplit) ?? false;
  Future<void> setSplitRouting(bool value) => _prefs.setBool(_kSplit, value);

  List<String> get directCountries {
    final raw = _prefs.getString(_kCountries);
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  Future<void> setDirectCountries(List<String> countries) =>
      _prefs.setString(_kCountries, countries.join(','));

  String get perAppMode => _prefs.getString(_kPerAppMode) ?? 'none';
  Future<void> setPerAppMode(String mode) => _prefs.setString(_kPerAppMode, mode);

  List<String> get perAppList {
    final raw = _prefs.getString(_kPerAppList);
    if (raw == null || raw.isEmpty) return [];
    return raw.split(',').where((s) => s.isNotEmpty).toList();
  }

  Future<void> setPerAppList(List<String> list) =>
      _prefs.setString(_kPerAppList, list.join(','));

  bool get insecure => _prefs.getBool(_kInsecure) ?? false;
  Future<void> setInsecure(bool value) => _prefs.setBool(_kInsecure, value);

  VpnConfig buildConfig({
    required String serverAddr,
    required String serverName,
    required String certPath,
    required String keyPath,
    String? caCertPath,
    required String tunAddr,
  }) {
    return VpnConfig(
      serverAddr: serverAddr,
      serverName: serverName,
      insecure: insecure,
      certPath: certPath,
      keyPath: keyPath,
      caCertPath: caCertPath,
      tunAddr: tunAddr,
      dnsServers: dnsServers,
      splitRouting: splitRouting,
      directCountries: directCountries,
      perAppMode: perAppMode,
      perAppList: perAppList,
    );
  }
}
