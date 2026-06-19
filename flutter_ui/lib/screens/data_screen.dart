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

class _RowState {
  const _RowState(this.label, this.progress, {this.isError = false});
  final String label;
  final double progress; // 0.0–1.0
  final bool isError;
}

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
  bool _processing = false;
  double _progress = 0;

  final _searchCtrl = TextEditingController();
  final _selectedIds = <String>{};
  final _logs = <LogEntry>[];
  final _logoEnabled = <String, bool>{};
  final _musicEnabled = <String, bool>{};
  final _rowStates = <String, _RowState>{};
  final _hScrollCtrl = ScrollController();

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
    super.dispose();
  }

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
          if (msg['type'] == 'data_changed') {
            _fetch(refresh: true);
          }
        },
        onDone: () => _scheduleReconnect(),
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

  Future<void> _fetch({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getLarkData(refresh: refresh);
      if (!mounted) return;
      // Init per-row toggles from Lark values
      _logoEnabled.clear();
      _musicEnabled.clear();
      for (final row in data.records) {
        final id = row['_record_id'] ?? '';
        if (id.isEmpty) continue;
        _logoEnabled[id] = true;
        _musicEnabled[id] = (row['Nhạc'] ?? '').toLowerCase() == 'yes';
      }
      setState(() {
        _data = data;
        _loading = false;
      });
    } on Exception catch (e) {
      if (mounted)
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
    }
  }

  List<Map<String, String>> get _filtered {
    if (_data == null) return [];
    if (_search.isEmpty) return _data!.records;
    final q = _search.toLowerCase();
    return _data!.records
        .where((r) => r.values.any((v) => v.toLowerCase().contains(q)))
        .toList();
  }

  void _addLog(String message, [LogType type = LogType.info]) {
    if (!mounted) return;
    final now = DateTime.now();
    final t =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    setState(() => _logs.add(LogEntry('[$t]', message, type)));
  }

  void _setRowState(String id, _RowState s) {
    if (mounted) setState(() => _rowStates[id] = s);
  }

  Future<void> _processSelected() async {
    if (_selectedIds.isEmpty) return;
    final cfg = await widget.api.getConfig();
    setState(() {
      _processing = true;
      _progress = 0;
    });

    final rows = _filtered;
    final toProcess =
        rows.where((r) => _selectedIds.contains(r['_record_id'])).toList();

    for (final row in toProcess) {
      final id = row['_record_id'] ?? '';
      if (id.isNotEmpty) _setRowState(id, const _RowState('Chờ xử lý...', 0));
    }

    // Run all rows in parallel
    await Future.wait(toProcess.map((row) => _processRow(row, cfg)));

    await _fetch();
    if (mounted)
      setState(() {
        _processing = false;
        _progress = 0;
        _selectedIds.clear();
      });
  }

  Future<void> _processRow(
      Map<String, String> row, Map<String, dynamic> cfg) async {
    final recordId = row['_record_id'] ?? '';
    final url = row['Link video Douyin'] ?? '';
    final useLogo = _logoEnabled[recordId] ?? true;
    final useMusic = _musicEnabled[recordId] ?? false;

    if (url.isEmpty) {
      _addLog(
          '⚠ ${recordId.substring(0, 6)}: không có URL, bỏ qua', LogType.warn);
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
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = msg['type'] as String? ?? 'info';
        final text = msg['message'] as String? ?? '';

        if (type == 'done') {
          final res = msg['result'] as Map<String, dynamic>? ?? {};
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

        _addLog(
            text,
            switch (type) {
              'success' => LogType.success,
              'error' => LogType.error,
              'warn' => LogType.warn,
              _ => LogType.info,
            });

        if (type == 'error') {
          _setRowState(recordId, _RowState('✗ $text', 1.0, isError: true));
        } else if (text.contains('Đang tải') ||
            text.contains('Connecting') ||
            text.contains('Downloading')) {
          _setRowState(recordId, const _RowState('Đang tải...', 0.20));
        } else if (text.contains('♪') || text.contains('Music')) {
          _setRowState(recordId, const _RowState('Đang xử lý...', 0.50));
        } else if (text.contains('Đang xử lý') || text.contains('ffmpeg')) {
          _setRowState(recordId, const _RowState('Đang xử lý...', 0.60));
        } else if (text.contains('Uploading') ||
            text.contains('Connecting to Google')) {
          _setRowState(recordId, const _RowState('Đang tải lên...', 0.80));
        } else {
          final pctMatch = RegExp(r'(\d+)%').firstMatch(text);
          if (pctMatch != null) {
            final pct = (int.tryParse(pctMatch.group(1)!) ?? 0) / 100.0;
            _setRowState(
                recordId,
                _RowState(
                    'Đang tải lên ${pctMatch.group(1)}%', 0.80 + pct * 0.18));
          }
        }
        if (mounted)
          setState(() => _progress = (_progress + 0.01).clamp(0.0, 0.95));
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
      setState(() => _selectedIds.clear());
      await _fetch(refresh: true);
    } on Exception catch (e) {
      _addLog('✗ Xóa thất bại: $e', LogType.error);
    }
  }

  Future<void> _showSubmitDialog() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Thêm URL vào hàng đợi',
            style: TextStyle(
                color: kText, fontSize: 14, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: ctrl,
            maxLines: 8,
            autofocus: true,
            style: const TextStyle(
                color: kText, fontSize: 12, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText:
                  'Dán text chia sẻ Douyin...\n(Ký tự € ở cuối = không chèn nhạc)',
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
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: kTextDim)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: kAccent,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5)),
            ),
            child: const Text('Thêm',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );

    final text = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || text.isEmpty || !mounted) return;

    final videos = DouyinParser.parse(text);
    if (videos.isEmpty) {
      _addLog('✗ Không tìm thấy URL Douyin hợp lệ', LogType.error);
      return;
    }

    try {
      final items =
          videos.map((v) => {'url': v.url, 'use_music': v.useMusic}).toList();
      final ids = await widget.api.submitToLark(items);
      _addLog('✓ Đã thêm ${ids.length} bản ghi vào hàng đợi', LogType.success);
      await _fetch(refresh: true);
    } on Exception catch (e) {
      _addLog('✗ Gửi thất bại: $e', LogType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: const BoxDecoration(
            color: kSidebar,
            border: Border(bottom: BorderSide(color: kBorder)),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.view_list_rounded, size: 18, color: kAccent),
              ),
              const SizedBox(width: 12),
              const Text('Hàng Đợi',
                  style: TextStyle(
                      color: kText, fontSize: 16, fontWeight: FontWeight.w700,
                      letterSpacing: -0.2)),
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
                        color: kAccent,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
              const Spacer(),
              // Search
              SizedBox(
                width: 220,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _search = v),
                  style: const TextStyle(color: kText, fontSize: 12.5),
                  decoration: InputDecoration(
                    hintText: 'Tìm kiếm...',
                    hintStyle: const TextStyle(color: kMuted, fontSize: 12.5),
                    prefixIcon: const Icon(Icons.search_rounded,
                        size: 16, color: kMuted),
                    filled: true,
                    fillColor: kInputBg,
                    isDense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
              // Submit URLs button
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
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                ),
              ),
              // Delete button — visible when rows selected
              if (_selectedIds.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ElevatedButton.icon(
                    onPressed: _processing ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline_rounded, size: 15),
                    label: Text(
                      'Xóa ${_selectedIds.length}',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
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
              // Process button — always visible
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ElevatedButton.icon(
                  onPressed: (_processing || _selectedIds.isEmpty)
                      ? null
                      : _processSelected,
                  icon: _processing
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Colors.white))
                      : const Icon(Icons.play_arrow_rounded, size: 16),
                  label: Text(
                    _processing
                        ? 'Đang xử lý...'
                        : _selectedIds.isEmpty
                            ? 'Xử lý'
                            : 'Xử lý ${_selectedIds.length}',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFF2563EB55),
                    disabledForegroundColor: Colors.white54,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                    elevation: 0,
                  ),
                ),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : _fetch,
                icon: _loading
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: kMuted))
                    : const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Làm mới', style: TextStyle(fontSize: 12.5)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: kTextDim,
                  side: const BorderSide(color: kBorder),
                  backgroundColor: kInputBg,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9)),
                ),
              ),
            ],
          ),
        ),

        // ── Body ────────────────────────────────────────────────────────────
        Expanded(
          child: Column(
            children: [
              Expanded(child: _buildBody()),
              _LogPane(
                logs: _logs,
                progress: _progress,
                running: _processing,
                onClose:
                    _processing ? null : () => setState(() => _logs.clear()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: kAccent, strokeWidth: 2),
            SizedBox(height: 16),
            Text('Đang tải dữ liệu Lark...',
                style: TextStyle(color: kTextDim, fontSize: 13)),
          ],
        ),
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
            border: Border.all(color: kRed.withOpacity(0.3)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, color: kRed, size: 36),
              const SizedBox(height: 12),
              const Text('Không thể tải dữ liệu',
                  style: TextStyle(
                      color: kText, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(_error!,
                  style: const TextStyle(color: kTextDim, fontSize: 12),
                  textAlign: TextAlign.center),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _fetch,
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Thử lại'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9)),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_data == null || _data!.fields.isEmpty) {
      return const Center(
          child: Text('Không có dữ liệu',
              style: TextStyle(color: kTextDim, fontSize: 13)));
    }

    final rows = _filtered;

    return Scrollbar(
      controller: _hScrollCtrl,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _hScrollCtrl,
        scrollDirection: Axis.horizontal,
        child: SingleChildScrollView(
          scrollDirection: Axis.vertical,
          padding: const EdgeInsets.all(16),
          child: _DataTable(
            fields: _data!.fields,
            rows: rows,
            selectedIds: _selectedIds,
            logoEnabled: _logoEnabled,
            musicEnabled: _musicEnabled,
            rowStates: _rowStates,
            onToggle: (id) => setState(() {
              if (_selectedIds.contains(id)) {
                _selectedIds.remove(id);
              } else {
                _selectedIds.add(id);
              }
            }),
            onSelectAll: (select) => setState(() {
              if (select) {
                _selectedIds.addAll(rows.map((r) => r['_record_id'] ?? ''));
              } else {
                _selectedIds.clear();
              }
            }),
            onLogoToggle: (id, v) => setState(() => _logoEnabled[id] = v),
            onMusicToggle: (id, v) => setState(() => _musicEnabled[id] = v),
          ),
        ),
      ),
    );
  }
}

// ── Data table ────────────────────────────────────────────────────────────────

class _DataTable extends StatelessWidget {
  final List<String> fields;
  final List<Map<String, String>> rows;
  final Set<String> selectedIds;
  final Map<String, bool> logoEnabled;
  final Map<String, bool> musicEnabled;
  final Map<String, _RowState> rowStates;
  final ValueChanged<String> onToggle;
  final ValueChanged<bool> onSelectAll;
  final void Function(String id, bool v) onLogoToggle;
  final void Function(String id, bool v) onMusicToggle;

  const _DataTable({
    required this.fields,
    required this.rows,
    required this.selectedIds,
    required this.logoEnabled,
    required this.musicEnabled,
    required this.rowStates,
    required this.onToggle,
    required this.onSelectAll,
    required this.onLogoToggle,
    required this.onMusicToggle,
  });

  @override
  Widget build(BuildContext context) {
    final allSelected = rows.isNotEmpty &&
        rows.every((r) => selectedIds.contains(r['_record_id']));

    // Nhạc rendered as toggle column — skip from regular data columns
    final dataFields = fields.where((f) => f != 'Nhạc').toList();
    final hasProgress = rowStates.isNotEmpty;

    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      border: TableBorder.all(color: kBorder, width: 1),
      children: [
        // Header
        TableRow(
          decoration: const BoxDecoration(color: Color(0xFFF8FAFC)),
          children: [
            _CheckCell(
              value: allSelected,
              onChanged: (v) => onSelectAll(v ?? false),
              isHeader: true,
            ),
            _HeaderCell('#'),
            _HeaderCell('LOGO'),
            _HeaderCell('NHẠC'),
            if (hasProgress) _HeaderCell('TIẾN ĐỘ'),
            ...dataFields.map((f) => _HeaderCell(f)),
          ],
        ),
        // Data rows
        for (var i = 0; i < rows.length; i++)
          TableRow(
            decoration: BoxDecoration(
              color: selectedIds.contains(rows[i]['_record_id'])
                  ? const Color(0xFFEFF6FF)
                  : i.isEven
                      ? Colors.white
                      : const Color(0xFFFAFAFC),
            ),
            children: [
              _CheckCell(
                value: selectedIds.contains(rows[i]['_record_id']),
                onChanged: (_) => onToggle(rows[i]['_record_id'] ?? ''),
              ),
              _IndexCell(i + 1),
              _ToggleCell(
                value: logoEnabled[rows[i]['_record_id']] ?? true,
                onChanged: (v) => onLogoToggle(rows[i]['_record_id'] ?? '', v),
              ),
              _ToggleCell(
                value: musicEnabled[rows[i]['_record_id']] ?? false,
                onChanged: (v) => onMusicToggle(rows[i]['_record_id'] ?? '', v),
              ),
              if (hasProgress) _ProgressCell(rowStates[rows[i]['_record_id']]),
              ...dataFields.map((f) => _DataCell(rows[i][f] ?? '', field: f)),
            ],
          ),
      ],
    );
  }
}

class _CheckCell extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?> onChanged;
  final bool isHeader;
  const _CheckCell(
      {required this.value, required this.onChanged, this.isHeader = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      alignment: Alignment.center,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      alignment: Alignment.center,
      child: Transform.scale(
        scale: 0.75,
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeColor: kAccent,
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
    if (state == null) {
      return const SizedBox(width: 160);
    }
    final isDone = state!.progress >= 1.0;
    final color = state!.isError
        ? kRed
        : isDone
            ? kGreen
            : kAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      width: 160,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            state!.label,
            style: TextStyle(
                color: color, fontSize: 10.5, fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis,
          ),
          if (!isDone) ...[
            const SizedBox(height: 5),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      constraints: const BoxConstraints(minWidth: 60, maxWidth: 260),
      child: Text(
        text,
        style: const TextStyle(
            color: kMuted,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _IndexCell extends StatelessWidget {
  final int idx;
  const _IndexCell(this.idx);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      alignment: Alignment.centerRight,
      child: Text('$idx',
          style: const TextStyle(
              color: kMuted, fontSize: 11, fontFamily: 'monospace')),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Lỗi mở liên kết: ${err.toString()}')));
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      constraints: const BoxConstraints(minWidth: 80, maxWidth: 260),
      child: _isUrl
          ? MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _openUrl(context),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const Icon(Icons.open_in_new,
                            size: 14, color: kAccent),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            text,
                            style: textStyle.copyWith(fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          : Text(
              text,
              style: textStyle,
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
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
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: const BoxDecoration(
              color: kSidebar,
              border: Border(bottom: BorderSide(color: kBorder)),
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.running ? kAmber : kGreen,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Nhật ký xử lý',
                    style: TextStyle(
                        color: kText,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
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
                    child: const Icon(Icons.close_rounded,
                        size: 14, color: kMuted),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              itemCount: widget.logs.length,
              itemBuilder: (_, i) => LogRow(entry: widget.logs[i]),
            ),
          ),
        ],
      ),
    );
  }
}
