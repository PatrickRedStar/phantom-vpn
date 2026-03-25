import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class RuleInfo {
  final String code;
  final String label;
  final int sizeKb;
  final DateTime? lastUpdated;
  final int cidrCount;

  const RuleInfo({
    required this.code,
    required this.label,
    this.sizeKb = 0,
    this.lastUpdated,
    this.cidrCount = 0,
  });
}

class RoutingRulesRepository {
  static const _baseUrl = 'https://raw.githubusercontent.com/v2fly/geoip/release/text';

  static const availableCountries = {
    'ru': 'Россия',
    'by': 'Беларусь',
    'kz': 'Казахстан',
    'ua': 'Украина',
    'cn': 'Китай',
    'ir': 'Иран',
    'private': 'Частные сети',
  };

  String? _rulesDir;

  Future<String> get _dir async {
    if (_rulesDir != null) return _rulesDir!;
    final appDir = await getApplicationDocumentsDirectory();
    _rulesDir = '${appDir.path}/routing_rules';
    await Directory(_rulesDir!).create(recursive: true);
    return _rulesDir!;
  }

  Future<List<RuleInfo>> getDownloadedRules() async {
    final dir = await _dir;
    final results = <RuleInfo>[];
    for (final entry in availableCountries.entries) {
      final file = File('$dir/${entry.key}.txt');
      if (file.existsSync()) {
        final stat = file.statSync();
        final lines = file.readAsLinesSync().where((l) => l.trim().isNotEmpty).length;
        results.add(RuleInfo(
          code: entry.key,
          label: entry.value,
          sizeKb: stat.size ~/ 1024,
          lastUpdated: stat.modified,
          cidrCount: lines,
        ));
      }
    }
    return results;
  }

  Future<bool> isDownloaded(String code) async {
    final dir = await _dir;
    return File('$dir/$code.txt').existsSync();
  }

  Future<void> downloadRuleList(String code) async {
    final url = '$_baseUrl/$code.txt';
    final resp = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) throw Exception('Download failed: ${resp.statusCode}');
    final dir = await _dir;
    await File('$dir/$code.txt').writeAsString(resp.body);
  }

  Future<void> deleteRuleList(String code) async {
    final dir = await _dir;
    final file = File('$dir/$code.txt');
    if (file.existsSync()) await file.delete();
  }

  Future<String?> mergeSelectedLists(List<String> codes) async {
    final dir = await _dir;
    final merged = StringBuffer();
    for (final code in codes) {
      final file = File('$dir/$code.txt');
      if (file.existsSync()) {
        merged.writeln(await file.readAsString());
      }
    }
    if (merged.isEmpty) return null;
    final outFile = File('$dir/direct_merged.txt');
    await outFile.writeAsString(merged.toString());
    return outFile.path;
  }
}
