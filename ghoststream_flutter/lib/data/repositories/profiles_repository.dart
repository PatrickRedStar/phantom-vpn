import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/vpn_profile.dart';
import '../../core/utils/conn_string_parser.dart';

class ProfilesRepository {
  List<VpnProfile> _profiles = [];
  String? _activeId;
  String? _filePath;

  List<VpnProfile> get profiles => List.unmodifiable(_profiles);
  String? get activeId => _activeId;

  VpnProfile? get activeProfile {
    if (_activeId == null) return _profiles.isNotEmpty ? _profiles.first : null;
    return _profiles.where((p) => p.id == _activeId).firstOrNull ?? _profiles.firstOrNull;
  }

  Future<void> load() async {
    final dir = await getApplicationDocumentsDirectory();
    _filePath = '${dir.path}/profiles.json';
    final file = File(_filePath!);
    if (!file.existsSync()) return;
    try {
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _activeId = json['activeId'] as String?;
      final list = json['profiles'] as List? ?? [];
      _profiles = list.map((e) => VpnProfile.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {}
  }

  Future<void> _save() async {
    if (_filePath == null) return;
    final json = {
      'activeId': _activeId,
      'profiles': _profiles.map((p) => p.toJson()).toList(),
    };
    await File(_filePath!).writeAsString(jsonEncode(json));
  }

  Future<void> addProfile(VpnProfile profile) async {
    _profiles.add(profile);
    _activeId ??= profile.id;
    await _save();
  }

  Future<void> updateProfile(VpnProfile profile) async {
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
      await _save();
    }
  }

  Future<void> deleteProfile(String id) async {
    final profile = _profiles.where((p) => p.id == id).firstOrNull;
    _profiles.removeWhere((p) => p.id == id);
    if (_activeId == id) {
      _activeId = _profiles.isNotEmpty ? _profiles.first.id : null;
    }
    if (profile != null) {
      _deleteFile(profile.certPath);
      _deleteFile(profile.keyPath);
      if (profile.caCertPath != null) _deleteFile(profile.caCertPath!);
    }
    await _save();
  }

  Future<void> setActiveId(String id) async {
    _activeId = id;
    await _save();
  }

  Future<VpnProfile> importFromConnString(String input, {String? name}) async {
    final parsed = ConnStringParser.parse(input);
    final dir = await getApplicationDocumentsDirectory();
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final profileDir = Directory('${dir.path}/profiles/$id');
    await profileDir.create(recursive: true);

    final certFile = File('${profileDir.path}/cert.pem');
    final keyFile = File('${profileDir.path}/key.pem');
    await certFile.writeAsString(parsed.cert);
    await keyFile.writeAsString(parsed.key);

    String? caPath;
    if (parsed.ca != null) {
      final caFile = File('${profileDir.path}/ca.pem');
      await caFile.writeAsString(parsed.ca!);
      caPath = caFile.path;
    }

    final sni = parsed.sni;
    final profileName = name?.isNotEmpty == true
        ? name!
        : sni.split('.').first.toUpperCase();

    final profile = VpnProfile(
      id: id,
      name: profileName,
      serverAddr: parsed.addr,
      serverName: sni,
      certPath: certFile.path,
      keyPath: keyFile.path,
      caCertPath: caPath,
      tunAddr: parsed.tun,
      adminUrl: parsed.adminUrl,
      adminToken: parsed.adminToken,
    );
    await addProfile(profile);
    return profile;
  }

  void _deleteFile(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
