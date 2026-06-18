import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/log_entry.dart';
import '../services/api_service.dart';
import '../utils/douyin_parser.dart';
import '../widgets/source_panel.dart';
import '../widgets/log_panel.dart';
import '../widgets/bottom_bar.dart';

class HomeScreen extends StatefulWidget {
  final ApiService api;
  final VoidCallback? onSubmitted;
  const HomeScreen({super.key, required this.api, this.onSubmitted});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _urlCtrl = TextEditingController();
  final _localPathCtrl = TextEditingController();
  final _gdriveCtrl = TextEditingController();

  bool _useLogo = true;
  bool _useMusic = false;
  int _destTab = 0;
  bool _running = false;
  double _progress = 0;
  String _logoPath = '';
  String _musicPath = '';
  String _reupDriveId = '';

  final _logs = <LogEntry>[
    const LogEntry('[00:00:00]', 'Đang khởi động engine...', LogType.info),
  ];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _localPathCtrl.dispose();
    _gdriveCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final cfg = await widget.api.getConfig();
      if (!mounted) return;
      setState(() {
        _useLogo = cfg['use_logo'] as bool? ?? true;
        _useMusic = cfg['use_music'] as bool? ?? false;
        _logoPath = cfg['logo_path'] as String? ?? '';
        _musicPath = cfg['music_path'] as String? ?? '';
        _reupDriveId = cfg['reup_gdrive_folder_id'] as String? ?? '';
        _gdriveCtrl.text = cfg['gdrive_folder_id'] as String? ?? '';
        _localPathCtrl.text = cfg['local_folder'] as String? ?? '';
        _destTab = (cfg['save_to'] as String? ?? 'drive') == 'local' ? 1 : 0;
      });
      _addLog('✓ Đã tải cấu hình', LogType.success);
    } on Exception {
      _addLog('⚠ Không kết nối được backend — chạy start_backend.bat trước',
          LogType.warn);
    }
  }

  void _addLog(String message, [LogType type = LogType.info]) {
    if (!mounted) return;
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    setState(() => _logs.add(LogEntry('[$h:$m:$s]', message, type)));
  }

  Future<void> _processVideo() async {
    final text = _urlCtrl.text.trim();
    if (text.isEmpty) {
      _addLog('✗ Vui lòng nhập URL Douyin', LogType.error);
      return;
    }
    final videos = DouyinParser.parse(text);
    if (videos.isEmpty) {
      _addLog('✗ Không tìm thấy URL Douyin hợp lệ', LogType.error);
      return;
    }

    await _refreshBackendSettings();

    setState(() {
      _running = true;
      _progress = 0;
    });

    for (var i = 0; i < videos.length; i++) {
      if (!mounted) break;
      final v = videos[i];
      if (videos.length > 1) {
        _addLog('▶ [${i + 1}/${videos.length}] ${v.url}', LogType.info);
      }
      // € = no music; otherwise respect global toggle
      await _processOne(v.url, v.useMusic ? _useMusic : false);
    }

    if (mounted)
      setState(() {
        _running = false;
        _progress = 0;
      });
  }

  Future<void> _processOne(String url, bool useMusic) async {
    try {
      final jobId = await widget.api.startJob({
        'url': url,
        'use_logo': _useLogo,
        'use_music': useMusic,
        'logo_path': _logoPath,
        'music_path': _musicPath,
        'save_to': _destTab == 0 ? 'drive' : 'local',
        'gdrive_folder_id': _gdriveCtrl.text.trim(),
        'reup_gdrive_folder_id': _reupDriveId.trim(),
        'local_folder': _localPathCtrl.text.trim(),
      });
      _addLog('▶ Job ${jobId.substring(0, 8)}… bắt đầu', LogType.info);

      final channel = widget.api.connectJobLogs(jobId);
      await for (final raw in channel.stream) {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = msg['type'] as String? ?? 'info';

        if (type == 'done') {
          final result = msg['result'] as Map<String, dynamic>? ?? {};
          if (result['status'] == 'success') {
            _addLog('✓ Hoàn thành!', LogType.success);
          } else {
            _addLog('✗ ${result['message'] ?? 'Unknown error'}', LogType.error);
          }
          break;
        }

        _addLog(
          msg['message'] as String? ?? '',
          switch (type) {
            'success' => LogType.success,
            'error' => LogType.error,
            'warn' => LogType.warn,
            _ => LogType.info,
          },
        );
        if (mounted) {
          setState(() => _progress = (_progress + 0.04).clamp(0.0, 0.92));
        }
      }
    } on Exception catch (e) {
      _addLog('✗ $e', LogType.error);
    }
  }

  Future<void> _submitToQueue() async {
    final text = _urlCtrl.text.trim();
    if (text.isEmpty) {
      _addLog('✗ Dán URL Douyin trước', LogType.error);
      return;
    }
    final videos = DouyinParser.parse(text);
    if (videos.isEmpty) {
      _addLog('✗ Không tìm thấy URL Douyin hợp lệ', LogType.error);
      return;
    }
    setState(() => _running = true);
    try {
      final items =
          videos.map((v) => {'url': v.url, 'use_music': v.useMusic}).toList();
      final ids = await widget.api.submitToLark(items);
      _addLog(
          '✓ Đã thêm ${ids.length} bản ghi vào hàng đợi Lark', LogType.success);
      widget.onSubmitted?.call();
    } on Exception catch (e) {
      _addLog('✗ Gửi thất bại: $e', LogType.error);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _refreshBackendSettings() async {
    try {
      final cfg = await widget.api.getConfig();
      if (!mounted) return;
      setState(() {
        _logoPath = cfg['logo_path'] as String? ?? _logoPath;
        _musicPath = cfg['music_path'] as String? ?? _musicPath;
        _reupDriveId = cfg['reup_gdrive_folder_id'] as String? ?? _reupDriveId;
        _gdriveCtrl.text =
            cfg['gdrive_folder_id'] as String? ?? _gdriveCtrl.text;
        _localPathCtrl.text =
            cfg['local_folder'] as String? ?? _localPathCtrl.text;
        _destTab = (cfg['save_to'] as String? ?? 'drive') == 'local' ? 1 : 0;
      });
    } on Exception {
      // Ignore refresh failures; use the most recent cached or typed values.
    }
  }

  Future<void> _saveConfig() async {
    try {
      await widget.api.saveConfig({
        'use_logo': _useLogo,
        'use_music': _useMusic,
        'logo_path': _logoPath,
        'music_path': _musicPath,
      });
      _addLog('✓ Đã lưu cấu hình', LogType.success);
    } on Exception catch (e) {
      _addLog('✗ Lưu thất bại: $e', LogType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 456,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      SourcePanel(ctrl: _urlCtrl),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: LogPanel(
                  logs: _logs,
                  progress: _progress,
                  running: _running,
                ),
              ),
            ],
          ),
        ),
        BottomBar(
          running: _running,
          onClear: () => setState(() => _logs.clear()),
          onSubmit: _running ? null : _submitToQueue,
          onProcess: _running ? null : _processVideo,
          onSave: _saveConfig,
        ),
      ],
    );
  }
}
