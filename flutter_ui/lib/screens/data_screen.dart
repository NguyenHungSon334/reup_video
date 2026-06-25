import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../constants/colors.dart';
import '../utils/open_url.dart';
import '../models/log_entry.dart';
import '../services/api_service.dart';
import '../utils/douyin_parser.dart';
import '../widgets/log_panel.dart';

// ── Layout constants ──────────────────────────────────────────────────────────
const double _kRowH         = 38;
const double _kHeaderH      = 36;
const double _kColCheck     = 44;
const double _kColIndex     = 50;
const double _kColToggle    = 64;
const double _kColProgress  = 180;
const double _kColMin       = 80;
const double _kColMax       = 260;
const double _kCharW        = 7.0;   // avg px per char at 11.5px font
const double _kCellHPad     = 24.0;  // 12px each side

// ── Row progress state ────────────────────────────────────────────────────────

class _RowState {
  const _RowState(this.label, this.progress, {this.isError = false});
  final String label;
  final double progress;
  final bool isError;
}

// ── Log notifier — decouples log/progress updates from table rebuilds ─────────

class _LogNotifier extends ChangeNotifier {
  final logs = <LogEntry>[];
  double progress = 0;

  void add(LogEntry e) {
    logs.add(e);
    notifyListeners();
  }

  void incrProgress() {
    progress = (progress + 0.01).clamp(0.0, 0.95);
    notifyListeners();
  }

  void reset() {
    progress = 0;
    notifyListeners();
  }

  void clear() {
    logs.clear();
    progress = 0;
    notifyListeners();
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class DataScreen extends StatefulWidget {
  final ApiService api;
  const DataScreen({super.key, required this.api});

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  LarkData? _data;
  bool _loading = false;
  String? _error;
  String _search = '';
  String? _statusFilter;
  String? _kenhFilter;
  bool _processing = false;

  // Phase 2: ValueNotifier — selection changes never trigger table rebuild
  final _selectionNotifier = ValueNotifier<Set<String>>({});
  Set<String> get _selectedIds => _selectionNotifier.value;

  final _logNotifier  = _LogNotifier();
  final _searchCtrl   = TextEditingController();
  final _logoEnabled  = <String, bool>{};
  final _musicEnabled = <String, bool>{};
  final _rowStates    = <String, _RowState>{};
  final _hScrollCtrl  = ScrollController();

  // Phase 1: cached column widths — invalidated when _data changes
  Map<String, double>? _colWidths;
  // Cached filter result — invalidated when _data/_search/_statusFilter change
  List<Map<String, String>>? _filteredCache;

  WebSocketChannel? _eventsChannel;
  StreamSubscription<dynamic>? _eventsSub;

  @override
  void initState() {
    super.initState();
    _fetch();
    _connectDataEvents();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _eventsChannel?.sink.close();
    _searchCtrl.dispose();
    _hScrollCtrl.dispose();
    _logNotifier.dispose();
    _selectionNotifier.dispose();
    super.dispose();
  }

  // ── WebSocket ───────────────────────────────────────────────────────────────

  void _connectDataEvents() {
    _eventsSub?.cancel();
    _eventsChannel?.sink.close();
    try {
      _eventsChannel = WebSocketChannel.connect(
          Uri.parse('${ApiService.wsBaseUrl}/ws/data-events'));
      _eventsSub = _eventsChannel!.stream.listen(
        (raw) {
          if (!mounted) return;
          final msg = jsonDecode(raw as String) as Map<String, dynamic>;
          if (msg['type'] != 'data_changed') return;
          final rawNew = msg['new_records'];
          if (rawNew is List && rawNew.isNotEmpty && _data != null) {
            final casted = rawNew
                .cast<Map<String, dynamic>>()
                .map((r) => r.map((k, v) => MapEntry(k, v?.toString() ?? '')))
                .toList();
            for (final r in casted) {
              final id = r['_record_id'] ?? '';
              if (id.isEmpty) continue;
              _logoEnabled[id] = true;
              _musicEnabled[id] = (r['Nhạc'] ?? '').toLowerCase() == 'yes';
            }
            setState(() {
              _data = LarkData(
                fields: _data!.fields,
                records: [...casted, ..._data!.records],
                total: _data!.total + casted.length,
              );
              _filteredCache = null;
            });
          } else {
            _fetch(refresh: true, silent: true);
          }
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: false,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    Future.delayed(const Duration(seconds: 5), () {
      if (mounted) _connectDataEvents();
    });
  }

  // ── Fetch ───────────────────────────────────────────────────────────────────

  Future<void> _fetch({bool refresh = false, bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await widget.api.getLarkData(refresh: refresh);
      if (!mounted) return;
      _logoEnabled.clear();
      _musicEnabled.clear();
      for (final row in data.records) {
        final id = row['_record_id'] ?? '';
        if (id.isEmpty) continue;
        _logoEnabled[id] = true;
        _musicEnabled[id] = (row['Nhạc'] ?? '').toLowerCase() == 'yes';
      }
      final reversed = LarkData(
        fields: data.fields,
        records: data.records.reversed.toList(),
        total: data.total,
      );
      setState(() {
        _data = reversed;
        _filteredCache = null;
        _colWidths = null; // Phase 1: invalidate on new data
        // Drop finished row states for records no longer in the loaded set
        if (_rowStates.isNotEmpty) {
          final liveIds = reversed.records.map((r) => r['_record_id'] ?? '').toSet();
          _rowStates.removeWhere((id, state) =>
              state.progress >= 1.0 && !liveIds.contains(id));
        }
        if (_statusFilter != null) {
          final existing = reversed.records
              .map((r) => r['Status'] ?? '')
              .where((s) => s.isNotEmpty)
              .toSet();
          if (!existing.contains(_statusFilter)) _statusFilter = null;
        }
        if (_kenhFilter != null) {
          final existing = reversed.records
              .map((r) => r['Kênh'] ?? '')
              .where((s) => s.isNotEmpty)
              .toSet();
          if (!existing.contains(_kenhFilter)) _kenhFilter = null;
        }
        if (!silent) _loading = false;
      });
    } on Exception catch (e) {
      if (mounted && !silent)
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
    }
  }

  // ── Computed properties ─────────────────────────────────────────────────────

  List<Map<String, String>> get _filtered => _filteredCache ??= _computeFiltered();

  List<Map<String, String>> _computeFiltered() {
    if (_data == null) return const [];
    var list = _data!.records;
    if (_statusFilter != null) {
      list = list.where((r) => r['Status'] == _statusFilter).toList();
    }
    if (_kenhFilter != null) {
      list = list.where((r) => r['Kênh'] == _kenhFilter).toList();
    }
    if (_search.isNotEmpty) {
      final q = _search.toLowerCase();
      list = list.where((r) => r.values.any((v) => v.toLowerCase().contains(q))).toList();
    }
    return list;
  }

  List<String> get _statusValues {
    if (_data == null) return [];
    return _data!.records
        .map((r) => r['Status'] ?? '')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  List<String> get _kenhValues {
    if (_data == null) return [];
    return _data!.records
        .map((r) => r['Kênh'] ?? '')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
  }

  // Phase 1: compute column widths once, cache until data changes
  Map<String, double> get _colWidthsMap => _colWidths ??= _computeColWidths();

  Map<String, double> _computeColWidths() {
    if (_data == null) return {};
    final fields = _data!.fields.where((f) => f != 'Nhạc').toList();
    final widths = <String, double>{};
    final sample = _data!.records.length > 200
        ? _data!.records.sublist(0, 200)
        : _data!.records;
    for (final field in fields) {
      double maxLen = field.length.toDouble();
      for (final r in sample) {
        final l = (r[field] ?? '').length.toDouble();
        if (l > maxLen) maxLen = l;
      }
      widths[field] = (maxLen * _kCharW + _kCellHPad).clamp(_kColMin, _kColMax);
    }
    return widths;
  }

  // ── Log helpers ─────────────────────────────────────────────────────────────

  void _addLog(String message, [LogType type = LogType.info]) {
    if (!mounted) return;
    final now = DateTime.now();
    final t = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    _logNotifier.add(LogEntry('[$t]', message, type));
  }

  void _setRowState(String id, _RowState s) {
    if (mounted) setState(() => _rowStates[id] = s);
  }

  // ── Selection helpers ───────────────────────────────────────────────────────

  void _toggleRow(String id) {
    final s = Set<String>.from(_selectionNotifier.value);
    s.contains(id) ? s.remove(id) : s.add(id);
    _selectionNotifier.value = s;
  }

  void _selectAll(bool select, List<Map<String, String>> rows) {
    _selectionNotifier.value = select
        ? rows.map((r) => r['_record_id'] ?? '').where((id) => id.isNotEmpty).toSet()
        : {};
  }

  // ── Process / Delete ────────────────────────────────────────────────────────

  Future<void> _processSelected() async {
    if (_selectedIds.isEmpty) return;
    final cfg = await widget.api.getConfig();
    _logNotifier.reset();
    setState(() => _processing = true);

    final rows = _filtered;
    final toProcess = rows.where((r) => _selectedIds.contains(r['_record_id'])).toList();

    for (final row in toProcess) {
      final id = row['_record_id'] ?? '';
      if (id.isNotEmpty) _setRowState(id, const _RowState('Chờ xử lý...', 0));
    }

    await Future.wait(toProcess.map((row) => _processRow(row, cfg)));

    await _fetch(silent: true);
    if (mounted)
      setState(() {
        _processing = false;
        _selectionNotifier.value = {};
      });
  }

  Future<void> _processRow(Map<String, String> row, Map<String, dynamic> cfg) async {
    final recordId = row['_record_id'] ?? '';
    final url = row['Link video Douyin'] ?? '';
    final useLogo  = _logoEnabled[recordId] ?? true;
    final useMusic = _musicEnabled[recordId] ?? false;

    if (url.isEmpty) {
      _addLog('⚠ ${recordId.substring(0, 6)}: không có URL, bỏ qua', LogType.warn);
      _setRowState(recordId, const _RowState('Bỏ qua', 1, isError: true));
      return;
    }

    _setRowState(recordId, const _RowState('Đang bắt đầu...', 0.05));

    try {
      final jobId = await widget.api.startJob({
        'url': url,
        'record_id': recordId,
        'use_logo': useLogo,
        'use_music': useMusic,
        'logo_path': cfg['logo_path'] ?? '',
        'music_path': cfg['music_path'] ?? '',
        'save_to': cfg['save_to'] ?? 'drive',
        'gdrive_folder_id': cfg['gdrive_folder_id'] ?? '',
        'reup_gdrive_folder_id': cfg['reup_gdrive_folder_id'] ?? '',
        'local_folder': cfg['local_folder'] ?? '',
      });

      final ch = widget.api.connectJobLogs(jobId);
      await for (final raw in ch.stream) {
        final msg  = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = msg['type'] as String? ?? 'info';
        final text = msg['message'] as String? ?? '';

        if (type == 'done') {
          final res     = msg['result'] as Map<String, dynamic>? ?? {};
          final success = res['status'] == 'success';
          if (success) {
            _addLog('✓ Hoàn thành: $url', LogType.success);
            _setRowState(recordId, const _RowState('✓ Xong', 1.0));
          } else {
            final errMsg = res['message'] as String? ?? 'lỗi';
            _addLog('✗ $errMsg', LogType.error);
            _setRowState(recordId, _RowState('✗ $errMsg', 1.0, isError: true));
          }
          break;
        }

        _addLog(text, switch (type) {
          'success' => LogType.success,
          'error'   => LogType.error,
          'warn'    => LogType.warn,
          _         => LogType.info,
        });

        if (type == 'error') {
          _setRowState(recordId, _RowState('✗ $text', 1.0, isError: true));
        } else if (text.contains('Đang tải') || text.contains('Connecting') || text.contains('Downloading')) {
          _setRowState(recordId, const _RowState('Đang tải...', 0.20));
        } else if (text.contains('♪') || text.contains('Music')) {
          _setRowState(recordId, const _RowState('Đang xử lý...', 0.50));
        } else if (text.contains('Đang xử lý') || text.contains('ffmpeg')) {
          _setRowState(recordId, const _RowState('Đang xử lý...', 0.60));
        } else if (text.contains('Uploading') || text.contains('Connecting to Google')) {
          _setRowState(recordId, const _RowState('Đang tải lên...', 0.80));
        } else {
          final pctMatch = RegExp(r'(\d+)%').firstMatch(text);
          if (pctMatch != null) {
            final pct = (int.tryParse(pctMatch.group(1)!) ?? 0) / 100.0;
            _setRowState(recordId,
                _RowState('Đang tải lên ${pctMatch.group(1)}%', 0.80 + pct * 0.18));
          }
        }
        _logNotifier.incrProgress();
      }
    } on Exception catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _addLog('✗ $msg', LogType.error);
      _setRowState(recordId, _RowState('✗ $msg', 1.0, isError: true));
    }
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final ids = _selectedIds.toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Xác nhận xóa',
            style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w700)),
        content: Text(
          'Bạn muốn xóa ${ids.length} bản ghi đã chọn?\nHành động này không thể hoàn tác.',
          style: const TextStyle(color: kTextDim, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: kTextDim)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: kRed,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
            ),
            child: const Text('Xóa', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final count = await widget.api.deleteRecords(ids);
      _addLog('✓ Đã xóa $count bản ghi', LogType.success);
      _selectionNotifier.value = {};
    } on Exception catch (e) {
      _addLog('✗ Xóa thất bại: $e', LogType.error);
    }
  }

  Future<void> _showSubmitDialog() async {
    final ctrl = TextEditingController();
    List<String> kenhOptions = [];

    try {
      kenhOptions = await widget.api.getKenhOptions();
    } on Exception {
      // kênh dropdown will be empty — still allow submit without it
    }

    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>?>(
      context: context,
      builder: (ctx) => _SubmitDialog(
        ctrl: ctrl,
        kenhOptions: kenhOptions,
      ),
    );

    final text = ctrl.text.trim();
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.dispose());
    if (result == null || text.isEmpty || !mounted) return;

    final kenh = result['kenh'] as String?;
    final videos = DouyinParser.parse(text);
    if (videos.isEmpty) {
      _addLog('✗ Không tìm thấy URL Douyin hợp lệ', LogType.error);
      return;
    }

    try {
      final items = videos.map((v) {
        final m = <String, dynamic>{'url': v.url, 'use_music': v.useMusic};
        if (kenh != null && kenh.isNotEmpty) m['kenh'] = kenh;
        return m;
      }).toList();
      final ids = await widget.api.submitToLark(items);
      _addLog('✓ Đã thêm ${ids.length} bản ghi vào hàng đợi', LogType.success);
    } on Exception catch (e) {
      _addLog('✗ Gửi thất bại: $e', LogType.error);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header toolbar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: const BoxDecoration(
            color: kSidebar,
            border: Border(bottom: BorderSide(color: kBorder)),
          ),
          child: Row(
            children: [
              Container(
                width: 34, height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.view_list_rounded, size: 18, color: kAccent),
              ),
              const SizedBox(width: 12),
              const Text('Hàng Đợi',
                  style: TextStyle(
                      color: kText, fontSize: 16,
                      fontWeight: FontWeight.w700, letterSpacing: -0.2)),
              if (_data != null) ...[
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFBFDBFE)),
                  ),
                  child: Text(
                    '${_filtered.length} / ${_data!.total}',
                    style: const TextStyle(
                        color: kAccent, fontSize: 10.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              const Spacer(),
              // Search
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() { _search = v; _filteredCache = null; }),
                  style: const TextStyle(color: kText, fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: 'Tìm kiếm...',
                    hintStyle: const TextStyle(color: kMuted, fontSize: 12.5),
                    prefixIcon: const Icon(Icons.search_rounded, size: 16, color: kMuted),
                    filled: true, fillColor: kInputBg, isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: kBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: kBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: kAccent, width: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Status filter
              if (_data != null && _statusValues.isNotEmpty)
                Builder(builder: (context) {
                  final safeFilter = _statusValues.contains(_statusFilter) ? _statusFilter : null;
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: kInputBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: safeFilter != null ? kAccent : kBorder),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: safeFilter,
                          isDense: true,
                          isExpanded: true,
                          style: const TextStyle(color: kText, fontSize: 12.5),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: kMuted),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Tất cả', style: TextStyle(color: kTextDim, fontSize: 12.5), overflow: TextOverflow.ellipsis),
                            ),
                            ..._statusValues.map((s) => DropdownMenuItem<String?>(
                                  value: s,
                                  child: Text(s, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
                                )),
                          ],
                          onChanged: (v) => setState(() { _statusFilter = v; _filteredCache = null; }),
                        ),
                      ),
                    ),
                  );
                }),
              const SizedBox(width: 10),
              // Kênh filter
              if (_data != null && _kenhValues.isNotEmpty)
                Builder(builder: (context) {
                  final safeFilter = _kenhValues.contains(_kenhFilter) ? _kenhFilter : null;
                  return ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: kInputBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: safeFilter != null ? kAccent : kBorder),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String?>(
                          value: safeFilter,
                          isDense: true,
                          isExpanded: true,
                          style: const TextStyle(color: kText, fontSize: 12.5),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: kMuted),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Tất cả kênh', style: TextStyle(color: kTextDim, fontSize: 12.5), overflow: TextOverflow.ellipsis),
                            ),
                            ..._kenhValues.map((s) => DropdownMenuItem<String?>(
                                  value: s,
                                  child: Text(s, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis),
                                )),
                          ],
                          onChanged: (v) => setState(() { _kenhFilter = v; _filteredCache = null; }),
                        ),
                      ),
                    ),
                  );
                }),
              const SizedBox(width: 10),
              // Add URL button
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton.icon(
                  onPressed: _processing ? null : _showSubmitDialog,
                  icon: const Icon(Icons.add_rounded, size: 15),
                  label: const Text('Thêm URL', style: TextStyle(fontSize: 12.5)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kAccent,
                    side: const BorderSide(color: Color(0xFFBFDBFE)),
                    backgroundColor: const Color(0xFFEFF6FF),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                  ),
                ),
              ),
              // Phase 2: selection-dependent buttons via ValueListenableBuilder
              // — no parent setState needed when selection changes
              ValueListenableBuilder<Set<String>>(
                valueListenable: _selectionNotifier,
                builder: (_, selected, __) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ElevatedButton.icon(
                          onPressed: _processing ? null : _deleteSelected,
                          icon: const Icon(Icons.delete_outline_rounded, size: 15),
                          label: Text('Xóa ${selected.length}',
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: kRed,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: const Color(0xFFEF444466),
                            disabledForegroundColor: Colors.white54,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                            elevation: 0,
                          ),
                        ),
                      ),
                    ],
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ElevatedButton.icon(
                        onPressed: (_processing || selected.isEmpty) ? null : _processSelected,
                        icon: _processing
                            ? const SizedBox(
                                width: 13, height: 13,
                                child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                            : const Icon(Icons.play_arrow_rounded, size: 16),
                        label: Text(
                          _processing
                              ? 'Đang xử lý...'
                              : selected.isEmpty ? 'Xử lý' : 'Xử lý ${selected.length}',
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: kAccent,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFF2563EB55),
                          disabledForegroundColor: Colors.white54,
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                          elevation: 0,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _fetch,
                icon: _loading
                    ? const SizedBox(
                        width: 13, height: 13,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: kMuted))
                    : const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Làm mới', style: TextStyle(fontSize: 12.5)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kTextDim,
                  side: const BorderSide(color: kBorder),
                  backgroundColor: kInputBg,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                ),
              ),
            ],
          ),
        ),

        // Body
        Expanded(
          child: Column(
            children: [
              Expanded(child: RepaintBoundary(child: _buildBody())),
              ListenableBuilder(
                listenable: _logNotifier,
                builder: (_, __) => _LogPane(
                  logs: _logNotifier.logs,
                  progress: _logNotifier.progress,
                  running: _processing,
                  onClose: _processing ? null : _logNotifier.clear,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Table body ────────────────────────────────────────────────────────────────

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: kAccent, strokeWidth: 2),
          SizedBox(height: 16),
          Text('Đang tải dữ liệu Lark...',
              style: TextStyle(color: kTextDim, fontSize: 13)),
        ]),
      );
    }

    if (_error != null) {
      return Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: kRed.withValues(alpha: 0.3)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline_rounded, color: kRed, size: 36),
            const SizedBox(height: 12),
            const Text('Không thể tải dữ liệu',
                style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: kTextDim, fontSize: 12),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _fetch,
              icon: const Icon(Icons.refresh_rounded, size: 15),
              label: const Text('Thử lại'),
              style: ElevatedButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                elevation: 0,
              ),
            ),
          ]),
        ),
      );
    }

    if (_data == null || _data!.fields.isEmpty) {
      return const Center(
          child: Text('Không có dữ liệu', style: TextStyle(color: kTextDim, fontSize: 13)));
    }

    final rows       = _filtered;
    final colWidths  = _colWidthsMap;
    final dataFields = _data!.fields.where((f) => f != 'Nhạc').toList();
    final hasProgress = _rowStates.isNotEmpty;

    // Total horizontal width (Phase 1: fixed, no measure)
    // Dividers: 3 between fixed cols + 1 for progress + 1 per data field
    final divCount = 3 + (hasProgress ? 1 : 0) + dataFields.length;
    double totalW = _kColCheck + _kColIndex + _kColToggle + _kColToggle + divCount;
    if (hasProgress) totalW += _kColProgress;
    for (final f in dataFields) totalW += colWidths[f] ?? _kColMin;

    // Phase 3: Column(header + ListView.builder) — avoids nested CustomScrollView
    // which triggers window.dart assertion on Flutter Web.
    // Header sits above Expanded(ListView) so it's always pinned at top.
    return SingleChildScrollView(
      controller: _hScrollCtrl,
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalW,
        child: Column(
          children: [
            // Pinned header
            ValueListenableBuilder<Set<String>>(
              valueListenable: _selectionNotifier,
              builder: (_, selected, __) {
                final allSel = rows.isNotEmpty &&
                    rows.every((r) => selected.contains(r['_record_id']));
                return _TableHeader(
                  dataFields: dataFields,
                  colWidths: colWidths,
                  hasProgress: hasProgress,
                  allSelected: allSel,
                  onSelectAll: (v) => _selectAll(v ?? false, rows),
                );
              },
            ),
            // Virtualized rows
            if (rows.isEmpty)
              const Expanded(
                child: Center(
                  child: Text('Không có kết quả',
                      style: TextStyle(color: kTextDim, fontSize: 13)),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: rows.length,
                  itemExtent: _kRowH,
                  itemBuilder: (_, i) {
                    final row = rows[i];
                    final id  = row['_record_id'] ?? '';
                    return ValueListenableBuilder<Set<String>>(
                      valueListenable: _selectionNotifier,
                      builder: (_, selected, __) => _TableRow(
                        index: i,
                        row: row,
                        dataFields: dataFields,
                        colWidths: colWidths,
                        hasProgress: hasProgress,
                        rowState: _rowStates[id],
                        isSelected: selected.contains(id),
                        logoEnabled: _logoEnabled[id] ?? true,
                        musicEnabled: _musicEnabled[id] ?? false,
                        onToggle: () => _toggleRow(id),
                        onLogoToggle: (v) => setState(() => _logoEnabled[id] = v),
                        onMusicToggle: (v) => setState(() => _musicEnabled[id] = v),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}


// ── Table header row ──────────────────────────────────────────────────────────

class _TableHeader extends StatelessWidget {
  final List<String> dataFields;
  final Map<String, double> colWidths;
  final bool hasProgress;
  final bool allSelected;
  final ValueChanged<bool?> onSelectAll;

  const _TableHeader({
    required this.dataFields,
    required this.colWidths,
    required this.hasProgress,
    required this.allSelected,
    required this.onSelectAll,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8FAFC),
        border: Border(
          top: BorderSide(color: kBorder),
          bottom: BorderSide(color: kBorder),
        ),
      ),
      child: Row(children: [
        _cell(_kColCheck, _CheckCell(value: allSelected, onChanged: onSelectAll, isHeader: true)),
        _div,
        _cell(_kColIndex, const _HeaderCell('#')),
        _div,
        _cell(_kColToggle, const _HeaderCell('LOGO')),
        _div,
        _cell(_kColToggle, const _HeaderCell('NHẠC')),
        if (hasProgress) ...[_div, _cell(_kColProgress, const _HeaderCell('TIẾN ĐỘ'))],
        ...dataFields.map((f) => Row(mainAxisSize: MainAxisSize.min, children: [
          _div,
          _cell(colWidths[f] ?? _kColMin, _HeaderCell(f)),
        ])),
      ]),
    );
  }

  static Widget _cell(double w, Widget child) => SizedBox(width: w, height: _kHeaderH, child: child);
  static const _div = VerticalDivider(width: 1, thickness: 1, color: kBorder);
}

// ── Table data row ────────────────────────────────────────────────────────────

class _TableRow extends StatelessWidget {
  final int index;
  final Map<String, String> row;
  final List<String> dataFields;
  final Map<String, double> colWidths;
  final bool hasProgress;
  final _RowState? rowState;
  final bool isSelected;
  final bool logoEnabled;
  final bool musicEnabled;
  final VoidCallback onToggle;
  final ValueChanged<bool> onLogoToggle;
  final ValueChanged<bool> onMusicToggle;

  const _TableRow({
    required this.index,
    required this.row,
    required this.dataFields,
    required this.colWidths,
    required this.hasProgress,
    required this.isSelected,
    required this.logoEnabled,
    required this.musicEnabled,
    required this.onToggle,
    required this.onLogoToggle,
    required this.onMusicToggle,
    this.rowState,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFFEFF6FF)
              : index.isEven ? Colors.white : const Color(0xFFFAFAFC),
          border: const Border(bottom: BorderSide(color: kBorder, width: 0.5)),
        ),
        child: Row(children: [
          _cell(_kColCheck, _CheckCell(value: isSelected, onChanged: (_) => onToggle())),
          _div,
          _cell(_kColIndex, _IndexCell(index + 1)),
          _div,
          _cell(_kColToggle, _ToggleCell(value: logoEnabled, onChanged: onLogoToggle)),
          _div,
          _cell(_kColToggle, _ToggleCell(value: musicEnabled, onChanged: onMusicToggle)),
          if (hasProgress) ...[_div, _cell(_kColProgress, _ProgressCell(rowState))],
          ...dataFields.map((f) => Row(mainAxisSize: MainAxisSize.min, children: [
            _div,
            _cell(colWidths[f] ?? _kColMin, _DataCell(row[f] ?? '', field: f)),
          ])),
        ]),
      ),
    );
  }

  static Widget _cell(double w, Widget child) => SizedBox(width: w, height: _kRowH, child: child);
  static const _div = VerticalDivider(width: 1, thickness: 1, color: kBorder);
}

// ── Cell widgets ──────────────────────────────────────────────────────────────

class _CheckCell extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?> onChanged;
  final bool isHeader;
  const _CheckCell({required this.value, required this.onChanged, this.isHeader = false});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Checkbox(
        value: value,
        onChanged: onChanged,
        side: const BorderSide(color: kBorder),
        activeColor: kAccent,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

class _ToggleCell extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleCell({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Transform.scale(
        scale: 0.75,
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: kAccent,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

class _ProgressCell extends StatelessWidget {
  final _RowState? state;
  const _ProgressCell(this.state);

  @override
  Widget build(BuildContext context) {
    if (state == null) return const SizedBox.shrink();
    final isDone = state!.progress >= 1.0;
    final color  = state!.isError ? kRed : isDone ? kGreen : kAccent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(state!.label,
              style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis),
          if (!isDone) ...[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: state!.progress,
                minHeight: 3,
                backgroundColor: kBorder,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String text;
  const _HeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          text,
          style: const TextStyle(
              color: kMuted, fontSize: 10.5,
              fontWeight: FontWeight.w700, letterSpacing: 0.7),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _IndexCell extends StatelessWidget {
  final int idx;
  const _IndexCell(this.idx);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Align(
        alignment: Alignment.centerRight,
        child: Text('$idx',
            style: const TextStyle(color: kMuted, fontSize: 11, fontFamily: 'monospace')),
      ),
    );
  }
}

class _DataCell extends StatelessWidget {
  final String text;
  final String field;
  const _DataCell(this.text, {this.field = ''});

  bool get _isUrl => text.startsWith('http://') || text.startsWith('https://');

  Future<void> _openUrl(BuildContext context) async {
    if (!_isUrl) return;
    try {
      await openUrl(text);
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Lỗi mở liên kết: $err')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Color textColor = kText;
    if (field == 'Status') {
      if (text.contains('✓') || text.contains('Hoàn thành')) {
        textColor = kGreen;
      } else if (text.contains('Lỗi') || text.contains('error')) {
        textColor = kRed;
      } else if (text.contains('Đang')) {
        textColor = kAmber;
      }
    }

    final textStyle = TextStyle(
      color: _isUrl ? kAccent : textColor,
      fontSize: 11.5,
      decoration: _isUrl ? TextDecoration.underline : TextDecoration.none,
      decorationThickness: _isUrl ? 1.5 : 0,
      decorationColor: _isUrl ? kAccent : null,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: _isUrl
          ? MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _openUrl(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(children: [
                    const Icon(Icons.open_in_new, size: 13, color: kAccent),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(text,
                          style: textStyle.copyWith(fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 2),
                    ),
                  ]),
                ),
              ),
            )
          : Align(
              alignment: Alignment.centerLeft,
              child: Text(text, style: textStyle,
                  overflow: TextOverflow.ellipsis, maxLines: 2),
            ),
    );
  }
}

// ── Log pane ──────────────────────────────────────────────────────────────────

class _LogPane extends StatefulWidget {
  final List<LogEntry> logs;
  final double progress;
  final bool running;
  final VoidCallback? onClose;

  const _LogPane({
    required this.logs,
    required this.progress,
    required this.running,
    this.onClose,
  });

  @override
  State<_LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends State<_LogPane> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(covariant _LogPane old) {
    super.didUpdateWidget(old);
    if (widget.logs.length != old.logs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      decoration: const BoxDecoration(
        color: kLogBg,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: const BoxDecoration(
            color: kSidebar,
            border: Border(bottom: BorderSide(color: kBorder)),
          ),
          child: Row(children: [
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                color: widget.running ? kAmber : kGreen,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            const Text('Nhật ký xử lý',
                style: TextStyle(color: kText, fontSize: 12, fontWeight: FontWeight.w600)),
            const Spacer(),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                width: 120,
                child: LinearProgressIndicator(
                  value: widget.running ? widget.progress : 1.0,
                  minHeight: 3,
                  backgroundColor: kBorder,
                  valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
                ),
              ),
            ),
            if (widget.onClose != null) ...[
              const SizedBox(width: 10),
              InkWell(
                onTap: widget.onClose,
                child: const Icon(Icons.close_rounded, size: 14, color: kMuted),
              ),
            ],
          ]),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            itemCount: widget.logs.length,
            itemBuilder: (_, i) => LogRow(entry: widget.logs[i]),
          ),
        ),
      ]),
    );
  }
}

// ── Submit dialog ─────────────────────────────────────────────────────────────

class _SubmitDialog extends StatefulWidget {
  final TextEditingController ctrl;
  final List<String> kenhOptions;

  const _SubmitDialog({
    required this.ctrl,
    required this.kenhOptions,
  });

  @override
  State<_SubmitDialog> createState() => _SubmitDialogState();
}

class _SubmitDialogState extends State<_SubmitDialog> {
  String? _selectedKenh;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      title: const Text('Thêm URL vào hàng đợi',
          style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w700)),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.kenhOptions.isNotEmpty) ...[
              const Text('Kênh', style: TextStyle(color: kTextDim, fontSize: 11.5, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                initialValue: _selectedKenh,
                hint: const Text('Chọn kênh...', style: TextStyle(color: kMuted, fontSize: 12.5)),
                isExpanded: true,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: kInputBg,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(5),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(5),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                ),
                style: const TextStyle(color: kText, fontSize: 12.5),
                dropdownColor: Colors.white,
                items: widget.kenhOptions
                    .map((o) => DropdownMenuItem(value: o, child: Text(o)))
                    .toList(),
                onChanged: (v) => setState(() => _selectedKenh = v),
              ),
              const SizedBox(height: 12),
            ],
            const Text('URL Douyin', style: TextStyle(color: kTextDim, fontSize: 11.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: widget.ctrl,
              maxLines: 7,
              autofocus: true,
              style: const TextStyle(color: kText, fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'Dán text chia sẻ Douyin...\n(Ký tự € ở cuối = không chèn nhạc)',
                hintStyle: const TextStyle(color: kMuted, fontSize: 11.5),
                filled: true,
                fillColor: kInputBg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(5),
                  borderSide: const BorderSide(color: kBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(5),
                  borderSide: const BorderSide(color: kBorder),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy', style: TextStyle(color: kTextDim)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, {'kenh': _selectedKenh}),
          style: ElevatedButton.styleFrom(
            backgroundColor: kAccent,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
          ),
          child: const Text('Thêm', style: TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
