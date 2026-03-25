import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/client_info.dart';

class AdminApiService {
  final String baseUrl;
  final String token;

  AdminApiService({required this.baseUrl, required this.token});

  Map<String, String> get _headers => {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };

  String get _base => baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  Future<ServerStatus> getStatus() async {
    final resp = await http.get(
      Uri.parse('$_base/api/status'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('Status ${resp.statusCode}');
    return ServerStatus.fromJson(jsonDecode(resp.body));
  }

  Future<List<ClientInfo>> getClients() async {
    final resp = await http.get(
      Uri.parse('$_base/api/clients'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('Status ${resp.statusCode}');
    final list = jsonDecode(resp.body) as List;
    return list.map((e) => ClientInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> createClient(String name, {int? expiresDays}) async {
    final body = <String, dynamic>{'name': name};
    if (expiresDays != null) body['expires_days'] = expiresDays;
    final resp = await http.post(
      Uri.parse('$_base/api/clients'),
      headers: _headers,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw Exception('Create failed: ${resp.statusCode}');
    }
  }

  Future<void> deleteClient(String name) async {
    final resp = await http.delete(
      Uri.parse('$_base/api/clients/$name'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('Delete failed: ${resp.statusCode}');
  }

  Future<void> toggleEnabled(String name, bool enable) async {
    final action = enable ? 'enable' : 'disable';
    final resp = await http.post(
      Uri.parse('$_base/api/clients/$name/$action'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('Toggle failed: ${resp.statusCode}');
  }

  Future<String?> getConnString(String name) async {
    final resp = await http.get(
      Uri.parse('$_base/api/clients/$name/conn_string'),
      headers: _headers,
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return null;
    final json = jsonDecode(resp.body);
    return json is Map ? json['conn_string'] as String? : resp.body;
  }

  Future<void> manageSubscription(String name, String action, {int? days}) async {
    final body = <String, dynamic>{'action': action};
    if (days != null) body['days'] = days;
    final resp = await http.post(
      Uri.parse('$_base/api/clients/$name/subscription'),
      headers: _headers,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) throw Exception('Subscription failed: ${resp.statusCode}');
  }
}
