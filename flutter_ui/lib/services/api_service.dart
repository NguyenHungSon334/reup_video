import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class ApiService {
  static String host = '127.0.0.1';
  static int port = kIsWeb ? 8000 : 8765;

  static const String _railwayUrl = 'https://web-production-ba657.up.railway.app';

  static bool get _isWebLocal {
    if (!kIsWeb) return false;
    final h = Uri.base.host;
    return h == 'localhost' || h == '127.0.0.1' || h.isEmpty;
  }

  static String get baseUrl {
    if (kIsWeb && !_isWebLocal) return _railwayUrl;
    return 'http://$host:$port';
  }

  static String get wsBaseUrl {
    if (kIsWeb && !_isWebLocal) {
      return _railwayUrl
          .replaceFirst('https://', 'wss://')
          .replaceFirst('http://', 'ws://');
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

  Future<List<String>> getKenhOptions() async {
    final res = await http
        .get(Uri.parse('${ApiService.baseUrl}/lark/kenh-options'))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return [];
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return (data['options'] as List).cast<String>();
  }

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

  Future<int> deleteRecords(List<String> recordIds) async {
    final res = await http
        .post(
          Uri.parse('${ApiService.baseUrl}/records/delete'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'record_ids': recordIds}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? 'Xóa thất bại');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    return data['deleted'] as int? ?? recordIds.length;
  }

  Future<LarkData> getLarkData({
    bool refresh = false,
    int page = 1,
    int pageSize = 0,
  }) async {
    const maxAttempts = 3;
    Exception? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      if (attempt > 0) {
        await Future.delayed(Duration(seconds: 4 * attempt));
      }
      try {
        final params = <String, String>{};
        if (refresh) params['refresh'] = 'true';
        if (pageSize > 0) {
          params['page'] = '$page';
          params['page_size'] = '$pageSize';
        }
        final uri = Uri.parse('${ApiService.baseUrl}/lark/data')
            .replace(queryParameters: params.isEmpty ? null : params);
        final res = await http.get(uri).timeout(const Duration(seconds: 90));
        if (res.statusCode == 502 || res.statusCode == 503) {
          lastError = Exception('Server đang khởi động lại (${res.statusCode}), thử lại...');
          continue;
        }
        if (res.statusCode != 200) {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          throw Exception(body['detail'] ?? 'Không thể tải dữ liệu Lark');
        }
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return LarkData.fromJson(data);
      } on Exception catch (e) {
        lastError = e;
        if (attempt == maxAttempts - 1) break;
      }
    }
    throw lastError ?? Exception('Không thể tải dữ liệu Lark');
  }
}

class LarkData {
  final List<String> fields;
  final List<Map<String, String>> records;
  final int total;
  final int? page;
  final int? pageSize;
  final int? totalPages;
  final bool hasMore;

  const LarkData({
    required this.fields,
    required this.records,
    required this.total,
    this.page,
    this.pageSize,
    this.totalPages,
    this.hasMore = false,
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
      page: json['page'] as int?,
      pageSize: json['page_size'] as int?,
      totalPages: json['total_pages'] as int?,
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}
