import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class UpdateService {
  static const String currentVersion = '1.0.0';
  static const String _githubApi =
      'https://api.github.com/repos/NguyenHungSon334/reup_video/releases/latest';

  static Future<({String version, String url})?> checkForUpdate() async {
    if (kIsWeb) return null;
    try {
      final res = await http.get(
        Uri.parse(_githubApi),
        headers: {'Accept': 'application/vnd.github+json'},
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
      if (!_isNewer(tag, currentVersion)) return null;
      final assets = (data['assets'] as List<dynamic>);
      final asset = assets.firstWhere(
        (a) => (a['name'] as String).endsWith('.exe'),
        orElse: () => assets.isNotEmpty ? assets.first : null,
      );
      if (asset == null) return null;
      return (version: tag, url: asset['browser_download_url'] as String);
    } on Exception {
      return null;
    }
  }

  static bool _isNewer(String remote, String current) {
    List<int> parse(String v) =>
        v.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final r = parse(remote);
    final c = parse(current);
    for (var i = 0; i < 3; i++) {
      final rv = i < r.length ? r[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (rv > cv) return true;
      if (rv < cv) return false;
    }
    return false;
  }
}
