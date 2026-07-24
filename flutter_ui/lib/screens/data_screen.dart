import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../constants/colors.dart';
import '../utils/open_url.dart';
import '../models/log_entry.dart';
import '../services/api_service.dart';
import '../utils/douyin_parser.dart';
import '../widgets/log_panel.dart';

// ── Layout constants ──────────────────────────────────────────────────────────
const double _kRowH         = 48;
const double _kHeaderH      = 42;
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
  static const int _maxLogs = 500; // cap so long runs don't blow up memory/GPU
  final logs = <LogEntry>[];
  double progress = 0;

  // Coalesce notifications: during processing many jobs stream progress at once.
  // Rebuilding the log pane + auto-scroll on every single event floods the GPU
  // (Context Lost on weak machines). Batch to at most ~7 rebuilds/sec instead.
  Timer? _throttle;
  static const _throttleMs = 140;
  bool _disposed = false;

  void _notifyThrottled() {
    if (_disposed || _throttle != null) return;
    _throttle = Timer(const Duration(milliseconds: _throttleMs), () {
      _throttle = null;
      if (!_disposed) notifyListeners();
    });
  }

  void add(LogEntry e) {
    if (_disposed) return;
    logs.add(e);
    if (logs.length > _maxLogs) {
      logs.removeRange(0, logs.length - _maxLogs);
    }
    _notifyThrottled();
  }

  void incrProgress() {
    if (_disposed) return;
    progress = (progress + 0.01).clamp(0.0, 0.95);
    _notifyThrottled();
  }

  void reset() {
    if (_disposed) return;
    progress = 0;
    notifyListeners();
  }

  void clear() {
    if (_disposed) return;
    logs.clear();
    progress = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _throttle?.cancel();
    super.dispose();
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

  // Client-side pagination
  static const int _pageSize = 50;
  int _page = 0;

  // Phase 2: ValueNotifier — selection changes never trigger table rebuild
  final _selectionNotifier = ValueNotifier<Set<String>>({});
  Set<String> get _selectedIds => _selectionNotifier.value;

  final _logNotifier  = _LogNotifier();
  final _searchCtrl   = TextEditingController();
  final _logoEnabled  = <String, bool>{};
  final _musicEnabled = <String, bool>{};
  final _bannerEnabled = <String, bool>{};
  final _rowStates    = <String, _RowState>{};
  // Per-row progress notifiers: streaming updates rebuild only the one row's
  // progress cell, never the whole screen (prevents GPU-context-lost freezes).
  final _rowNotifiers = <String, ValueNotifier<_RowState?>>{};
  final _hScrollCtrl  = ScrollController();

  Set<String>? _visibleFields; // null = not yet initialized
  double _logPaneHeight = 180;

  // Phase 1: cached column widths — invalidated when _data changes
  Map<String, double>? _colWidths;
  // Cached filter result — invalidated when _data/_search/_statusFilter change
  List<Map<String, String>>? _filteredCache;

  WebSocketChannel? _eventsChannel;
  StreamSubscription<dynamic>? _eventsSub;

  // Jobs still running on the backend: recordId -> jobId. Persisted so that
  // leaving this screen (or restarting the app) doesn't orphan them — the
  // backend keeps a replayable log buffer, we just reconnect to it.
  static const String _kActiveJobsKey = 'active_jobs';
  // Static: a batch started by a previous State can still be dispatching jobs
  // after that State was disposed. Sharing one map keeps those tracked.
  static final _activeJobs = <String, String>{};

  @override
  void initState() {
    super.initState();
    _fetch();
    _connectDataEvents();
    _restoreJobs();
  }

  @override
  void dispose() {
    _eventsSub?.cancel();
    _eventsChannel?.sink.close();
    _searchCtrl.dispose();
    _hScrollCtrl.dispose();
    _logNotifier.dispose();
    _selectionNotifier.dispose();
    for (final n in _rowNotifiers.values) {
      n.dispose();
    }
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
              _bannerEnabled[id] = true;
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
      _bannerEnabled.clear();
      _musicEnabled.clear();
      for (final row in data.records) {
        final id = row['_record_id'] ?? '';
        if (id.isEmpty) continue;
        _logoEnabled[id] = true;
        _bannerEnabled[id] = true;
        _musicEnabled[id] = (row['Nhạc'] ?? '').toLowerCase() == 'yes';
      }
      // Backend already sorts newest-created first.
      setState(() {
        _data = data;
        _filteredCache = null;
        _colWidths = null; // Phase 1: invalidate on new data
        if (_visibleFields == null) {
          final allFields = data.fields.where((f) => f != 'Nhạc').toSet();
          _visibleFields = allFields.where((f) =>
              data.records.any((r) => (r[f] ?? '').isNotEmpty)).toSet();
        }
        // Drop finished row states for records no longer in the loaded set
        if (_rowStates.isNotEmpty) {
          final liveIds = data.records.map((r) => r['_record_id'] ?? '').toSet();
          _rowStates.removeWhere((id, state) {
            final drop = state.progress >= 1.0 && !liveIds.contains(id);
            if (drop) _rowNotifiers.remove(id)?.dispose();
            return drop;
          });
        }
        if (_statusFilter != null) {
          final existing = data.records
              .map((r) => r['Status'] ?? '')
              .where((s) => s.isNotEmpty)
              .toSet();
          if (!existing.contains(_statusFilter)) _statusFilter = null;
        }
        if (_kenhFilter != null) {
          final existing = data.records
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

  // ── Column visibility ───────────────────────────────────────────────────────

  Set<String> _computeDefaultVisibleFields() {
    if (_data == null) return {};
    final fields = _data!.fields.where((f) => f != 'Nhạc').toList();
    return fields.where((f) => _data!.records.any((r) => (r[f] ?? '').isNotEmpty)).toSet();
  }

  Future<void> _showColumnPicker(BuildContext context) async {
    if (_data == null) return;
    final fields = _data!.fields.where((f) => f != 'Nhạc').toList();
    final current = Set<String>.from(_visibleFields ?? fields.toSet());
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, ss) => AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          title: const Text('Cột hiển thị',
              style: TextStyle(color: kText, fontSize: 14, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 280,
            height: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: ListView(
                    shrinkWrap: true,
                    children: fields.map((f) => CheckboxListTile(
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: Text(f, style: const TextStyle(fontSize: 12.5, color: kText)),
                      value: current.contains(f),
                      activeColor: kAccent,
                      onChanged: (v) => ss(() => v! ? current.add(f) : current.remove(f)),
                    )).toList(),
                  ),
                ),
                const Divider(height: 16),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => ss(() => current.addAll(fields)),
                      child: const Text('Tất cả', style: TextStyle(fontSize: 12, color: kAccent)),
                    ),
                    TextButton(
                      onPressed: () => ss(() {
                        current.clear();
                        current.addAll(_computeDefaultVisibleFields());
                      }),
                      child: const Text('Mặc định', style: TextStyle(fontSize: 12, color: kMuted)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx2),
              style: ElevatedButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: Colors.white, elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Xong', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() { _visibleFields = current; _colWidths = null; });
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

  ValueNotifier<_RowState?> _rowNotifier(String id) =>
      _rowNotifiers.putIfAbsent(id, () => ValueNotifier<_RowState?>(null));

  void _setRowState(String id, _RowState s) {
    if (!mounted) return;
    _rowNotifier(id).value = s; // per-row rebuild, no full-screen setState
    if (_rowStates.containsKey(id)) {
      _rowStates[id] = s; // bookkeeping only (no rebuild) for the common case
    } else {
      // First state for this row → reveal the progress column once.
      setState(() => _rowStates[id] = s);
    }
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

  // Cap concurrency: the backend already throttles ffmpeg/Playwright, and N
  // simultaneous job streams flood the UI with progress events → freezes.
  // Kept low (2) so weak machines don't lose the GPU context under the flood.
  static const int _kMaxConcurrent = 2;

  /// Rows waiting for a free worker. A standing queue rather than a local list:
  /// it lets a second "Xử lý" press append to a run that is already going, and
  /// it lets a queued row be pulled back out when the user stops it.
  final _queue = <Map<String, String>>[];
  int _workers = 0;

  bool _isQueued(String id) => _queue.any((r) => r['_record_id'] == id);

  Future<void> _processSelected() async {
    if (_selectedIds.isEmpty) return;
    final cfg = await widget.api.getConfig();
    if (!mounted) return;

    // Only reset the log when starting from idle — otherwise we would wipe the
    // log of the rows still running.
    if (_workers == 0) _logNotifier.reset();

    final selected = _selectedIds;
    final toQueue = _filtered.where((r) {
      final id = r['_record_id'] ?? '';
      // Skip anything already running or already waiting: pressing "Xử lý"
      // twice on the same row must not start it twice.
      return id.isNotEmpty &&
          selected.contains(id) &&
          !_activeJobs.containsKey(id) &&
          !_isQueued(id);
    }).toList();

    if (toQueue.isEmpty) {
      _addLog('⚠ Các dòng đã chọn đang chạy hoặc đã ở trong hàng đợi', LogType.warn);
      return;
    }

    for (final row in toQueue) {
      _setRowState(row['_record_id']!, const _RowState('Chờ xử lý...', 0));
    }
    _queue.addAll(toQueue);
    _addLog('+ Thêm ${toQueue.length} video vào hàng đợi (${_queue.length} đang chờ)',
        LogType.info);

    setState(() {
      _processing = true;
      _selectionNotifier.value = {};
    });

    while (_workers < _kMaxConcurrent && _queue.isNotEmpty) {
      _workers++;
      unawaited(_runWorker(cfg));
    }
  }

  /// Pulls rows off the shared queue until it runs dry. One slow row therefore
  /// only occupies its own slot; the other worker keeps draining the queue.
  Future<void> _runWorker(Map<String, dynamic> cfg) async {
    try {
      while (mounted && _queue.isNotEmpty) {
        await _processRow(_queue.removeAt(0), cfg);
      }
    } finally {
      _workers--;
      if (_workers == 0) {
        await _fetch(silent: true);
        if (mounted) setState(() => _processing = false);
      }
    }
  }

  /// Stop one row: drop it from the queue if it hasn't started, otherwise ask
  /// the backend to cancel its job. The job's own log socket reports the stop.
  Future<void> _cancelRow(String recordId) async {
    _queue.removeWhere((r) => r['_record_id'] == recordId);

    final jobId = _activeJobs[recordId];
    if (jobId == null) {
      _setRowState(recordId, const _RowState('⏹ Đã bỏ khỏi hàng đợi', 1.0, isError: true));
      return;
    }

    _setRowState(recordId, const _RowState('⏹ Đang dừng...', 0.99));
    try {
      await widget.api.cancelJob(jobId);
    } on Exception catch (e) {
      _addLog('⚠ Không gửi được lệnh dừng: $e', LogType.warn);
    }
  }

  // ── Job persistence / reattach ──────────────────────────────────────────────

  Future<void> _persistJobs() async {
    final prefs = await SharedPreferences.getInstance();
    if (_activeJobs.isEmpty) {
      await prefs.remove(_kActiveJobsKey);
    } else {
      await prefs.setString(_kActiveJobsKey, jsonEncode(_activeJobs));
    }
  }

  /// Reconnect to jobs that were still running when this screen went away.
  /// The backend replays each job's full log history from the start.
  Future<void> _restoreJobs() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    // Union of what's on disk (previous app run) and what's still in memory
    // (a batch that outlived the previous State).
    final saved = <String, String>{..._activeJobs};
    final raw = prefs.getString(_kActiveJobsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        saved.addAll((jsonDecode(raw) as Map).cast<String, String>());
      } on FormatException {
        await prefs.remove(_kActiveJobsKey);
      }
    }
    if (saved.isEmpty || !mounted) return;

    _activeJobs.addAll(saved);
    setState(() => _processing = true);
    _addLog('↻ Kết nối lại ${saved.length} job đang chạy...', LogType.info);
    for (final id in saved.keys) {
      _setRowState(id, const _RowState('↻ Kết nối lại...', 0.05));
    }

    await Future.wait(
        saved.entries.map((e) => _streamJob(e.value, e.key, '')));

    await _fetch(silent: true);
    if (mounted) setState(() => _processing = false);
  }

  Future<void> _processRow(Map<String, String> row, Map<String, dynamic> cfg) async {
    final recordId = row['_record_id'] ?? '';
    final url = row['Link video Douyin'] ?? '';
    final useLogo   = _logoEnabled[recordId] ?? true;
    final useBanner = _bannerEnabled[recordId] ?? true;
    final useMusic  = _musicEnabled[recordId] ?? false;

    if (url.isEmpty) {
      _addLog('⚠ ${recordId.substring(0, 6)}: không có URL, bỏ qua', LogType.warn);
      _setRowState(recordId, const _RowState('Bỏ qua', 1, isError: true));
      return;
    }

    _setRowState(recordId, const _RowState('Đang bắt đầu...', 0.05));

    final String jobId;
    try {
      jobId = await widget.api.startJob({
        'url': url,
        'record_id': recordId,
        'use_logo': useLogo,
        'use_banner': useBanner,
        'use_music': useMusic,
        'logo_path': cfg['logo_path'] ?? '',
        'music_path': cfg['music_path'] ?? '',
        'save_to': cfg['save_to'] ?? 'drive',
        'gdrive_folder_id': cfg['gdrive_folder_id'] ?? '',
        'reup_gdrive_folder_id': cfg['reup_gdrive_folder_id'] ?? '',
        'local_folder': cfg['local_folder'] ?? '',
      });
    } on Exception catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _addLog('✗ $msg', LogType.error);
      _setRowState(recordId, _RowState('✗ $msg', 1.0, isError: true));
      return;
    }

    _activeJobs[recordId] = jobId;
    unawaited(_persistJobs());
    await _streamJob(jobId, recordId, url);
  }

  /// Consume a job's log websocket. Safe to call on a fresh job or on a
  /// reconnect — the backend replays the job's history from the beginning.
  Future<void> _streamJob(String jobId, String recordId, String url) async {
    final label = url.isEmpty ? recordId : url;
    try {
      final ch = widget.api.connectJobLogs(jobId);
      await for (final raw in ch.stream) {
        if (!mounted) {
          await ch.sink.close();
          break;
        }
        final msg  = jsonDecode(raw as String) as Map<String, dynamic>;
        final type = msg['type'] as String? ?? 'info';
        final text = msg['message'] as String? ?? '';

        if (type == 'done') {
          final res     = msg['result'] as Map<String, dynamic>? ?? {};
          final success = res['status'] == 'success';
          if (success) {
            _addLog('✓ Hoàn thành: $label', LogType.success);
            _setRowState(recordId, const _RowState('✓ Xong', 1.0));
          } else if (res['status'] == 'cancelled') {
            _addLog('⏹ Đã dừng: $label', LogType.warn);
            _setRowState(recordId, const _RowState('⏹ Đã dừng', 1.0, isError: true));
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
        } else if (text.contains('Xử lý video:')) {
          // Real ffmpeg percent → map into the processing band 0.55–0.80.
          final m = RegExp(r'(\d+)%').firstMatch(text);
          final pct = (int.tryParse(m?.group(1) ?? '0') ?? 0) / 100.0;
          // Show "frame X/Y" in the row label when ffmpeg reported it.
          final fm = RegExp(r'frame \d+(?:/\d+)?').firstMatch(text);
          final label = fm != null
              ? 'Xử lý ${m?.group(1) ?? '0'}% · ${fm.group(0)}'
              : 'Đang xử lý ${m?.group(1) ?? '0'}%';
          _setRowState(recordId, _RowState(label, 0.55 + pct * 0.25));
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
        if (mounted) _logNotifier.incrProgress();
      }
    } on Exception catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      _addLog('✗ $msg', LogType.error);
      _setRowState(recordId, _RowState('✗ $msg', 1.0, isError: true));
    } finally {
      // Only forget the job when we actually saw it through. If the screen was
      // disposed mid-stream, keep the entry on disk so _restoreJobs() can
      // reattach to it.
      if (mounted) {
        _activeJobs.remove(recordId);
        unawaited(_persistJobs());
      }
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
                  onChanged: (v) => setState(() { _search = v; _filteredCache = null; _page = 0; }),
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
                          onChanged: (v) => setState(() { _statusFilter = v; _filteredCache = null; _page = 0; }),
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
                          onChanged: (v) => setState(() { _kenhFilter = v; _filteredCache = null; _page = 0; }),
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
                        // Stays enabled while a run is going: the selection is
                        // appended to the running queue instead of starting a
                        // second, competing run.
                        onPressed: selected.isEmpty ? null : _processSelected,
                        icon: _processing
                            ? const SizedBox(
                                width: 13, height: 13,
                                child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                            : const Icon(Icons.play_arrow_rounded, size: 16),
                        label: Text(
                          selected.isEmpty
                              ? (_processing ? 'Đang xử lý...' : 'Xử lý')
                              : _processing
                                  ? 'Thêm ${selected.length} vào hàng đợi'
                                  : 'Xử lý ${selected.length}',
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
              const SizedBox(width: 8),
              Tooltip(
                message: 'Ẩn/hiện cột',
                child: OutlinedButton(
                  onPressed: _data != null ? () => _showColumnPicker(context) : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kTextDim,
                    side: const BorderSide(color: kBorder),
                    backgroundColor: kInputBg,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    minimumSize: Size.zero,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
                  ),
                  child: const Icon(Icons.view_column_rounded, size: 16),
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
              _buildPager(),
              ListenableBuilder(
                listenable: _logNotifier,
                builder: (_, __) => _LogPane(
                  logs: _logNotifier.logs,
                  progress: _logNotifier.progress,
                  running: _processing,
                  height: _logPaneHeight,
                  onClose: _processing ? null : _logNotifier.clear,
                  onResize: (dy) => setState(() {
                    _logPaneHeight = (_logPaneHeight - dy).clamp(80.0, 520.0);
                  }),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── Pager ─────────────────────────────────────────────────────────────────────

  Widget _buildPager() {
    if (_data == null) return const SizedBox.shrink();
    final total = _filtered.length;
    if (total <= _pageSize) return const SizedBox.shrink();
    final pageCount = (total + _pageSize - 1) ~/ _pageSize;
    final page = _page.clamp(0, pageCount - 1);
    final from = page * _pageSize + 1;
    final to = ((page + 1) * _pageSize).clamp(0, total);

    Widget navBtn(IconData icon, bool enabled, VoidCallback onTap) => IconButton(
          onPressed: enabled ? onTap : null,
          icon: Icon(icon, size: 18),
          color: kTextDim,
          disabledColor: kBorder,
          visualDensity: VisualDensity.compact,
          splashRadius: 18,
        );

    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: kSidebar,
        border: Border(top: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Text('$from–$to / $total',
              style: const TextStyle(color: kTextDim, fontSize: 12)),
          const Spacer(),
          navBtn(Icons.first_page_rounded, page > 0, () => setState(() => _page = 0)),
          navBtn(Icons.chevron_left_rounded, page > 0, () => setState(() => _page = page - 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text('Trang ${page + 1}/$pageCount',
                style: const TextStyle(color: kText, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          navBtn(Icons.chevron_right_rounded, page < pageCount - 1, () => setState(() => _page = page + 1)),
          navBtn(Icons.last_page_rounded, page < pageCount - 1, () => setState(() => _page = pageCount - 1)),
        ],
      ),
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

    final allRows    = _filtered;
    final total      = allRows.length;
    final pageCount  = total == 0 ? 1 : ((total + _pageSize - 1) ~/ _pageSize);
    final page       = _page.clamp(0, pageCount - 1);
    final start      = page * _pageSize;
    final end        = (start + _pageSize) > total ? total : start + _pageSize;
    final rows       = total == 0 ? const <Map<String, String>>[] : allRows.sublist(start, end);
    final colWidths  = _colWidthsMap;
    final visible    = _visibleFields;
    final dataFields = _data!.fields
        .where((f) => f != 'Nhạc' && (visible == null || visible.contains(f)))
        .toList();
    final hasProgress = _rowStates.isNotEmpty;

    // Total horizontal width (Phase 1: fixed, no measure)
    // Dividers: 4 between fixed cols + 1 for progress + 1 per data field
    final divCount = 4 + (hasProgress ? 1 : 0) + dataFields.length;
    double totalW = _kColCheck + _kColIndex + _kColToggle * 3 + divCount;
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
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Bulk action banner
                    if (selected.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                        decoration: const BoxDecoration(
                          color: Color(0xFFEFF6FF),
                          border: Border(bottom: BorderSide(color: Color(0xFFBFDBFE))),
                        ),
                        child: Row(children: [
                          const Icon(Icons.check_box_rounded, size: 14, color: kAccent),
                          const SizedBox(width: 8),
                          Text(
                            '${selected.length} bản ghi đã chọn',
                            style: const TextStyle(color: kAccent, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _processSelected,
                            icon: const Icon(Icons.play_arrow_rounded, size: 14),
                            label: Text(
                                _processing ? 'Thêm ${selected.length}' : 'Xử lý ${selected.length}',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            style: TextButton.styleFrom(foregroundColor: kAccent),
                          ),
                          const SizedBox(width: 4),
                          TextButton.icon(
                            onPressed: _processing ? null : _deleteSelected,
                            icon: const Icon(Icons.delete_outline_rounded, size: 14),
                            label: Text('Xóa ${selected.length}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                            style: TextButton.styleFrom(foregroundColor: kRed),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: () => _selectionNotifier.value = {},
                            borderRadius: BorderRadius.circular(4),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(Icons.close_rounded, size: 14, color: kMuted),
                            ),
                          ),
                        ]),
                      ),
                    _TableHeader(
                      dataFields: dataFields,
                      colWidths: colWidths,
                      hasProgress: hasProgress,
                      allSelected: allSel,
                      onSelectAll: (v) => _selectAll(v ?? false, rows),
                    ),
                  ],
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
                    // Descending numbering: largest at top (start of list)
                    final displayNumber = total - (start + i);
                    return ValueListenableBuilder<Set<String>>(
                      valueListenable: _selectionNotifier,
                      builder: (_, selected, __) => _TableRow(
                        index: i,
                        displayNumber: displayNumber,
                        row: row,
                        dataFields: dataFields,
                        colWidths: colWidths,
                        hasProgress: hasProgress,
                        rowStateListenable: _rowNotifiers[id],
                        isSelected: selected.contains(id),
                        logoEnabled: _logoEnabled[id] ?? true,
                        bannerEnabled: _bannerEnabled[id] ?? true,
                        musicEnabled: _musicEnabled[id] ?? false,
                        onToggle: () => _toggleRow(id),
                        onLogoToggle: (v) => setState(() => _logoEnabled[id] = v),
                        onBannerToggle: (v) => setState(() => _bannerEnabled[id] = v),
                        onMusicToggle: (v) => setState(() => _musicEnabled[id] = v),
                        onCancel: () => _cancelRow(id),
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
        color: Color(0xFFF2F4F7),
        border: Border(
          top: BorderSide(color: Color(0xFFCDD4DC)),
          bottom: BorderSide(color: Color(0xFFCDD4DC), width: 1.5),
        ),
      ),
      child: Row(children: [
        _cell(_kColCheck, _CheckCell(value: allSelected, onChanged: onSelectAll, isHeader: true)),
        _div,
        _cell(_kColIndex, const _HeaderCell('#')),
        _div,
        _cell(_kColToggle, const _HeaderCell('LOGO')),
        _div,
        _cell(_kColToggle, const _HeaderCell('BANNER')),
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
  static const _div = VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE4E9EF));
}

// ── Table data row ────────────────────────────────────────────────────────────

class _TableRow extends StatefulWidget {
  final int index;
  final int displayNumber;
  final Map<String, String> row;
  final List<String> dataFields;
  final Map<String, double> colWidths;
  final bool hasProgress;
  final ValueListenable<_RowState?>? rowStateListenable;
  final bool isSelected;
  final bool logoEnabled;
  final bool bannerEnabled;
  final bool musicEnabled;
  final VoidCallback onToggle;
  final ValueChanged<bool> onLogoToggle;
  final ValueChanged<bool> onBannerToggle;
  final ValueChanged<bool> onMusicToggle;
  final VoidCallback? onCancel;

  const _TableRow({
    required this.index,
    required this.displayNumber,
    required this.row,
    required this.dataFields,
    required this.colWidths,
    required this.hasProgress,
    required this.isSelected,
    required this.logoEnabled,
    required this.bannerEnabled,
    required this.musicEnabled,
    required this.onToggle,
    required this.onLogoToggle,
    required this.onBannerToggle,
    required this.onMusicToggle,
    this.rowStateListenable,
    this.onCancel,
  });

  @override
  State<_TableRow> createState() => _TableRowState();
}

class _TableRowState extends State<_TableRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color rowBg;
    if (widget.isSelected) {
      rowBg = const Color(0xFFEBF2FF);
    } else if (_hovered) {
      rowBg = const Color(0xFFF0F4FF);
    } else {
      rowBg = widget.index.isEven ? Colors.white : const Color(0xFFF8FAFB);
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onToggle,
        child: Container(
          decoration: BoxDecoration(
            color: rowBg,
            border: const Border(bottom: BorderSide(color: Color(0xFFDDE3EA), width: 0.8)),
          ),
          child: Row(children: [
            _cell(_kColCheck, _CheckCell(value: widget.isSelected, onChanged: (_) => widget.onToggle())),
            _div,
            _cell(_kColIndex, _IndexCell(widget.displayNumber)),
            _div,
            _cell(_kColToggle, _ToggleCell(value: widget.logoEnabled, onChanged: widget.onLogoToggle, icon: Icons.image_rounded, activeColor: kAccent)),
            _div,
            _cell(_kColToggle, _ToggleCell(value: widget.bannerEnabled, onChanged: widget.onBannerToggle, icon: Icons.view_carousel_rounded, activeColor: const Color(0xFF0EA5E9))),
            _div,
            _cell(_kColToggle, _ToggleCell(value: widget.musicEnabled, onChanged: widget.onMusicToggle, icon: Icons.music_note_rounded, activeColor: const Color(0xFF7C3AED))),
            if (widget.hasProgress) ...[
              _div,
              _cell(_kColProgress, widget.rowStateListenable == null
                  ? const _ProgressCell(null)
                  : ValueListenableBuilder<_RowState?>(
                      valueListenable: widget.rowStateListenable!,
                      builder: (_, rs, __) => _ProgressCell(rs, onCancel: widget.onCancel),
                    )),
            ],
            ...widget.dataFields.map((f) => Row(mainAxisSize: MainAxisSize.min, children: [
              _div,
              _cell(widget.colWidths[f] ?? _kColMin, _DataCell(widget.row[f] ?? '', field: f)),
            ])),
          ]),
        ),
      ),
    );
  }

  static Widget _cell(double w, Widget child) => SizedBox(width: w, height: _kRowH, child: child);
  static const _div = VerticalDivider(width: 1, thickness: 1, color: Color(0xFFE4E9EF));
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
  final IconData icon;
  final Color activeColor;
  const _ToggleCell({
    required this.value,
    required this.onChanged,
    required this.icon,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => onChanged(!value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 34, height: 22,
            decoration: BoxDecoration(
              color: value ? activeColor.withValues(alpha: 0.12) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: value ? activeColor.withValues(alpha: 0.45) : kBorder,
              ),
            ),
            child: Icon(icon, size: 13, color: value ? activeColor : kMuted),
          ),
        ),
      ),
    );
  }
}

class _ProgressCell extends StatelessWidget {
  final _RowState? state;
  final VoidCallback? onCancel;
  const _ProgressCell(this.state, {this.onCancel});

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
          Row(children: [
            Expanded(
              child: Text(state!.label,
                  style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis),
            ),
            // Stop button, only while this row still has work to give up on.
            if (!isDone && onCancel != null)
              SizedBox(
                width: 20,
                height: 20,
                child: IconButton(
                  padding: EdgeInsets.zero,
                  iconSize: 15,
                  splashRadius: 12,
                  tooltip: 'Dừng dòng này',
                  icon: const Icon(Icons.stop_circle_outlined, color: kRed),
                  onPressed: onCancel,
                ),
              ),
          ]),
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
              color: Color(0xFF4A5568), fontSize: 11,
              fontWeight: FontWeight.w600, letterSpacing: 0.5),
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

  String _shortenUrl(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final last = segments.isNotEmpty ? segments.last : '';
      final short = last.length > 10 ? '…${last.substring(last.length - 8)}' : last;
      if (host.contains('douyin')) return 'douyin/$short';
      if (host.contains('google')) return 'drive/$short';
      return '${host.replaceAll('www.', '')}/$short';
    } catch (_) {
      return url.length > 28 ? '${url.substring(0, 25)}…' : url;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Status pill badge
    if (field == 'Status' && text.isNotEmpty) {
      final Color bg;
      final Color fg;
      if (text.contains('✓') || text.contains('Hoàn thành')) {
        bg = const Color(0xFFDCFCE7); fg = kGreen;
      } else if (text.contains('Lỗi') || text.contains('error')) {
        bg = const Color(0xFFFEE2E2); fg = kRed;
      } else if (text.contains('Đang')) {
        bg = const Color(0xFFFEF3C7); fg = kAmber;
      } else {
        bg = const Color(0xFFF1F5F9); fg = kMuted;
      }
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: fg.withValues(alpha: 0.35)),
            ),
            child: Text(text,
                style: TextStyle(color: fg, fontSize: 10.5, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }

    if (_isUrl) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Tooltip(
          message: text,
          waitDuration: const Duration(milliseconds: 400),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => _openUrl(context),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.open_in_new_rounded, size: 11, color: kAccent),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(_shortenUrl(text),
                        style: const TextStyle(color: kAccent, fontSize: 11, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1),
                  ),
                ]),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(text,
            style: const TextStyle(color: kText, fontSize: 11.5),
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
  final double height;
  final VoidCallback? onClose;
  final ValueChanged<double>? onResize;

  const _LogPane({
    required this.logs,
    required this.progress,
    required this.running,
    required this.height,
    this.onClose,
    this.onResize,
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
          // jumpTo (no per-frame animation) — cheaper on GPU during log floods.
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
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
    return SizedBox(
      height: widget.height,
      child: Column(children: [
        // Drag handle
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            onVerticalDragUpdate: (d) => widget.onResize?.call(d.delta.dy),
            child: Container(
              height: 6,
              color: const Color(0xFFF2F4F7),
              child: Center(
                child: Container(
                  width: 36, height: 3,
                  decoration: BoxDecoration(
                    color: const Color(0xFFCDD4DC),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Container(
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
      ])),
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
