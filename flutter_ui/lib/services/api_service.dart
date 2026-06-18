import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ApiService {
  static String host = '127.0.0.1';
  static int port = 8000;

  // ⚠️ Cập nhật URL backend từ Render tại đây (sau khi deploy)
  // Ví dụ: https://reup-backend.onrender.com
  static String backendUrl = ''; // Để trống = same-origin (localhost:8000)

  static String get baseUrl {
    if (kIsWeb) {
      // Nếu có backendUrl, dùng nó. Nếu không, dùng same-origin
      if (backendUrl.isNotEmpty) {
        return backendUrl;
      }
      // Same-origin (localhost:8000 hoặc domain.com:8000)
      return 'http://${Uri.base.host}:8000';
    }
    return 'http://$host:$port';
  }

  static String get wsBaseUrl {
    if (kIsWeb) {
      final scheme = Uri.base.scheme == 'https' ? 'wss' : 'ws';
      if (backendUrl.isNotEmpty) {
        // Chuyển https:// → wss://, http:// → ws://
        final wsUrl = backendUrl.replaceFirst('https://', 'wss://')
                                .replaceFirst('http://', 'ws://');
        return wsUrl;
      }
      return '$scheme://${Uri.base.authority}';
    }
    return 'ws://$host:$port';
  }

  // ── Config ────────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getConfig() async {
    final res = await http
        .get(Uri.parse('${ApiService.baseUrl}/config'))
        .timeout(const Duration(seconds: 5));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> saveConfig(Map<String, dynamic> config) async {
    await http.post(
      Uri.parse('${ApiService.baseUrl}/config'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config),
    );
  }

  // ── Jobs ──────────────────────────────────────────────────────────────────

  Future<String> startJob(Map<String, dynamic> params) async {
    final res = await http.post(
      Uri.parse('${ApiService.baseUrl}/jobs'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(params),
    );
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['job_id'] as String;
  }

  WebSocketChannel connectJobLogs(String jobId) =>
      WebSocketChannel.connect(Uri.parse('${ApiService.wsBaseUrl}/ws/$jobId'));

  // ── Lark ──────────────────────────────────────────────────────────────────

  Future<List<String>> submitToLark(List<Map<String, dynamic>> items) async {
    final res = await http
        .post(
          Uri.parse('${ApiService.baseUrl}/records/submit'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'items': items}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? 'Gửi dữ liệu thất bại');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['record_ids'] as List).cast<String>();
  }

  // ── Google Drive ──────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> gdriveStatus() async {
    final res = await http
        .get(Uri.parse('${ApiService.baseUrl}/gdrive/status'))
        .timeout(const Duration(seconds: 10));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> gdriveList(String folderId) async {
    final uri = Uri.parse(
        '${ApiService.baseUrl}/gdrive/list${folderId.isNotEmpty ? '?folder_id=${Uri.encodeComponent(folderId)}' : ''}');
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? 'Không thể liệt kê Drive');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (data['files'] as List).cast<Map<String, dynamic>>();
    return items;
  }

  Future<Map<String, dynamic>> gdriveUpload(
      PlatformFile file, String folderId) async {
    final uri = Uri.parse('${ApiService.baseUrl}/gdrive/upload');
    final req = http.MultipartRequest('POST', uri);
    if (folderId.isNotEmpty) req.fields['folder_id'] = folderId;

    if (file.path != null && file.path!.isNotEmpty) {
      final multipart = await http.MultipartFile.fromPath('file', file.path!);
      req.files.add(multipart);
    } else if (file.bytes != null) {
      final multipart = http.MultipartFile.fromBytes('file', file.bytes!,
          filename: file.name);
      req.files.add(multipart);
    } else {
      throw Exception('No file bytes or path available');
    }

    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception(body['error'] ?? body['detail'] ?? 'Upload thất bại');
    }
    return body;
  }

  Future<void> gdriveConnect() async {
    final res = await http
        .post(Uri.parse('${ApiService.baseUrl}/gdrive/connect'))
        .timeout(const Duration(minutes: 3)); // OAuth can take time
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? 'Kết nối thất bại');
    }
  }

  Future<LarkData> getLarkData() async {
    final res = await http
        .get(Uri.parse('${ApiService.baseUrl}/lark/data'))
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? 'Không thể tải dữ liệu Lark');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return LarkData.fromJson(data);
  }
}

class LarkData {
  final List<String> fields;
  final List<Map<String, String>> records;
  final int total;

  const LarkData({
    required this.fields,
    required this.records,
    required this.total,
  });

  factory LarkData.fromJson(Map<String, dynamic> json) {
    final fields = (json['fields'] as List).cast<String>();
    final records = (json['records'] as List)
        .map((r) => (r as Map<String, dynamic>).map(
              (k, v) => MapEntry(k, v?.toString() ?? ''),
            ))
        .toList();
    return LarkData(
      fields: fields,
      records: records,
      total: json['total'] as int? ?? records.length,
    );
  }
}
