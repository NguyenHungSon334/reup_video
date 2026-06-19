import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../constants/colors.dart';
import '../services/api_service.dart';
import '../widgets/panel_card.dart';
import '../widgets/dest_panel.dart';

class SettingsScreen extends StatefulWidget {
  final ApiService api;
  final Future<void> Function(String host, int port) onBackendChanged;

  const SettingsScreen({
    super.key,
    required this.api,
    required this.onBackendChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _hostCtrl = TextEditingController(text: ApiService.host);
  final _portCtrl = TextEditingController(text: ApiService.port.toString());
  final _gdriveCtrl = TextEditingController();
  final _reupDriveCtrl = TextEditingController();
  final _gdriveCredCtrl = TextEditingController();
  final _localPathCtrl = TextEditingController();
  final _musicFolderCtrl = TextEditingController();
  final _musicDriveCtrl = TextEditingController();
  final _logoPathCtrl = TextEditingController();
  final _logoDriveCtrl = TextEditingController();
  final _appIdCtrl = TextEditingController();
  final _appSecretCtrl = TextEditingController();
  final _cookiesBrowserCtrl = TextEditingController();
  final _cookiesFileCtrl = TextEditingController();

  int _destTab = 0;
  int _logoScale = 150;
  String _logoPosition = 'top_left';
  double _logoOpacity = 1.0;
  bool _obscureSecret = true;
  bool _saving = false;
  String? _message;
  bool _msgIsError = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _gdriveCtrl.dispose();
    _reupDriveCtrl.dispose();
    _gdriveCredCtrl.dispose();
    _localPathCtrl.dispose();
    _musicFolderCtrl.dispose();
    _musicDriveCtrl.dispose();
    _logoPathCtrl.dispose();
    _logoDriveCtrl.dispose();
    _appIdCtrl.dispose();
    _appSecretCtrl.dispose();
    _cookiesBrowserCtrl.dispose();
    _cookiesFileCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final cfg = await widget.api.getConfig();
      if (!mounted) return;
      setState(() {
        _gdriveCtrl.text = cfg['gdrive_folder_id'] as String? ?? '';
        _reupDriveCtrl.text = cfg['reup_gdrive_folder_id'] as String? ?? '';
        _gdriveCredCtrl.text = cfg['gdrive_credentials_path'] as String? ?? '';
        _localPathCtrl.text = cfg['local_folder'] as String? ?? '';
        _musicFolderCtrl.text = cfg['music_folder'] as String? ?? '';
        _musicDriveCtrl.text = cfg['music_gdrive_folder_id'] as String? ?? '';
        _logoPathCtrl.text = cfg['logo_path'] as String? ?? '';
        _logoDriveCtrl.text = cfg['logo_gdrive_folder_id'] as String? ?? '';
        _appIdCtrl.text = cfg['lark_app_id'] as String? ?? '';
        _appSecretCtrl.text = cfg['lark_app_secret'] as String? ?? '';
        _cookiesBrowserCtrl.text = cfg['cookies_browser'] as String? ?? '';
        _cookiesFileCtrl.text = cfg['cookies_file'] as String? ?? '';
        _destTab = (cfg['save_to'] as String? ?? 'drive') == 'local' ? 1 : 0;
        _logoScale = (cfg['logo_scale'] as num?)?.toInt() ?? 150;
        _logoPosition = cfg['logo_position'] as String? ?? 'top_left';
        _logoOpacity = (cfg['logo_opacity'] as num?)?.toDouble() ?? 1.0;
      });
    } on Exception {
      _showMsg('Không kết nối được backend', isError: true);
    }
  }

  void _showMsg(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _msgIsError = isError;
    });
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) setState(() => _message = null);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Save backend host/port to local storage
      final host =
          _hostCtrl.text.trim().isEmpty ? '127.0.0.1' : _hostCtrl.text.trim();
      final port = int.tryParse(_portCtrl.text.trim()) ?? 8000;
      await widget.onBackendChanged(host, port);

      // Save other settings to backend config
      await widget.api.saveConfig({
        'save_to': _destTab == 0 ? 'drive' : 'local',
        'gdrive_credentials_path': _gdriveCredCtrl.text.trim(),
        'local_folder': _localPathCtrl.text.trim(),
        'music_folder': _musicFolderCtrl.text.trim(),
        'music_gdrive_folder_id': _musicDriveCtrl.text.trim(),
        'logo_path': _logoPathCtrl.text.trim(),
        'logo_gdrive_folder_id': _logoDriveCtrl.text.trim(),
        'logo_scale': _logoScale,
        'logo_position': _logoPosition,
        'logo_opacity': _logoOpacity,
        'cookies_browser': _cookiesBrowserCtrl.text.trim(),
        'cookies_file': _cookiesFileCtrl.text.trim(),
      });
      _showMsg('✓ Đã lưu cài đặt');
    } on Exception catch (e) {
      _showMsg('✗ $e', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ── Header ────────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: kBorder)),
          ),
          child: Row(
            children: [
              const Text('Cài Đặt',
                  style: TextStyle(
                      color: kText, fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              if (_message != null)
                AnimatedOpacity(
                  opacity: 1,
                  duration: const Duration(milliseconds: 200),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color:
                          (_msgIsError ? kRed : kGreen).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(
                        color: (_msgIsError ? kRed : kGreen)
                            .withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      _message!,
                      style: TextStyle(
                          color: _msgIsError ? kRed : kGreen, fontSize: 12),
                    ),
                  ),
                ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: Colors.white))
                    : const Icon(Icons.save_rounded, size: 15),
                label: const Text('Lưu cài đặt',
                    style:
                        TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                  elevation: 0,
                ),
              ),
            ],
          ),
        ),

        // ── Content ───────────────────────────────────────────────────────────
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _BackendSection(hostCtrl: _hostCtrl, portCtrl: _portCtrl),
                const SizedBox(height: 16),
                _OutputSection(
                  destTab: _destTab,
                  onTab: (t) => setState(() => _destTab = t),
                  gdriveCtrl: _gdriveCtrl,
                  reupDriveCtrl: _reupDriveCtrl,
                  gdriveCredCtrl: _gdriveCredCtrl,
                  localCtrl: _localPathCtrl,
                  api: widget.api,
                ),
                const SizedBox(height: 16),
                _MediaSection(
                  musicFolderCtrl: _musicFolderCtrl,
                  musicDriveCtrl: _musicDriveCtrl,
                  logoPathCtrl: _logoPathCtrl,
                  logoDriveCtrl: _logoDriveCtrl,
                  api: widget.api,
                  logoScale: _logoScale,
                  logoPosition: _logoPosition,
                  logoOpacity: _logoOpacity,
                  onScaleChanged: (v) => setState(() => _logoScale = v),
                  onPositionChanged: (v) => setState(() => _logoPosition = v),
                  onOpacityChanged: (v) => setState(() => _logoOpacity = v),
                ),
                const SizedBox(height: 16),
                _LarkSection(
                  appIdCtrl: _appIdCtrl,
                  appSecretCtrl: _appSecretCtrl,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Backend section ───────────────────────────────────────────────────────────

class _BackendSection extends StatelessWidget {
  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  const _BackendSection({required this.hostCtrl, required this.portCtrl});

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'KẾT NỐI BACKEND',
      actionWidget: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: kGreen.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: kGreen.withValues(alpha: 0.3)),
        ),
        child: const Text('LOCAL',
            style: TextStyle(
                color: kGreen,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('IP / Host Backend',
              style: TextStyle(
                  color: kMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9)),
          const SizedBox(height: 6),
          DarkInput(ctrl: hostCtrl, hint: '127.0.0.1'),
          const SizedBox(height: 12),
          const Text('Cổng',
              style: TextStyle(
                  color: kMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9)),
          const SizedBox(height: 6),
          SizedBox(
            width: 120,
            child: DarkInput(ctrl: portCtrl, hint: '8000'),
          ),
          const SizedBox(height: 10),
          // Backend startup instructions removed (local setup information)
        ],
      ),
    );
  }
}

// ── Output section ────────────────────────────────────────────────────────────

class _OutputSection extends StatefulWidget {
  final int destTab;
  final ValueChanged<int> onTab;
  final TextEditingController gdriveCtrl;
  final TextEditingController reupDriveCtrl;
  final TextEditingController gdriveCredCtrl;
  final TextEditingController localCtrl;
  final ApiService api;
  const _OutputSection({
    required this.destTab,
    required this.onTab,
    required this.gdriveCtrl,
    required this.reupDriveCtrl,
    required this.gdriveCredCtrl,
    required this.localCtrl,
    required this.api,
  });

  @override
  State<_OutputSection> createState() => _OutputSectionState();
}

class _OutputSectionState extends State<_OutputSection> {
  bool? _connected; // null = unknown, true = ok, false = not connected
  String _statusMsg = '';
  bool _checking = false;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    setState(() {
      _checking = true;
      _statusMsg = '';
    });
    try {
      final res = await widget.api.gdriveStatus();
      if (!mounted) return;
      setState(() {
        _connected = res['connected'] as bool? ?? false;
        _statusMsg =
            _connected! ? '' : (res['reason'] as String? ?? 'Chưa kết nối');
        _checking = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _statusMsg = 'Không thể kết nối backend: $e';
        _checking = false;
      });
    }
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _statusMsg = 'Đang mở trình duyệt để xác thực...';
    });
    try {
      await widget.api.gdriveConnect();
      if (!mounted) return;
      setState(() {
        _connected = true;
        _statusMsg = '';
        _connecting = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _connected = false;
        _statusMsg = e.toString().replaceFirst('Exception: ', '');
        _connecting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'ĐÍCH LƯU KẾT QUẢ',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 34,
            decoration: BoxDecoration(
              color: kInputBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: kBorder),
            ),
            child: Row(
              children: [
                DestTab(
                    label: 'Google Drive',
                    active: widget.destTab == 0,
                    onTap: () => widget.onTab(0)),
                DestTab(
                    label: 'Thư mục cục bộ',
                    active: widget.destTab == 1,
                    onTap: () => widget.onTab(1)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (widget.destTab == 0) ...[
            // Status row
            Row(
              children: [
                _checking
                    ? const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                            strokeWidth: 1.5, color: kMuted))
                    : Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _connected == null
                              ? kMuted
                              : _connected!
                                  ? kGreen
                                  : kRed,
                        ),
                      ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _checking
                        ? 'Đang kiểm tra...'
                        : _connected == true
                            ? 'Đã kết nối Google Drive'
                            : _statusMsg.isNotEmpty
                                ? _statusMsg
                                : 'Chưa kết nối',
                    style: TextStyle(
                      color: _connected == true ? kGreen : kTextDim,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _checking ? null : _checkStatus,
                  icon: const Icon(Icons.refresh_rounded, size: 13),
                  label: const Text('Kiểm tra', style: TextStyle(fontSize: 11)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kTextDim,
                    side: const BorderSide(color: kBorder),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5)),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  onPressed: (_connecting || _checking) ? null : _connect,
                  icon: _connecting
                      ? const SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                              strokeWidth: 1.5, color: Colors.white))
                      : const Icon(Icons.link_rounded, size: 13),
                  label: Text(_connecting ? 'Đang kết nối...' : 'Kết nối',
                      style: const TextStyle(fontSize: 11)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5)),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    elevation: 0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text('ID Thư mục Google Drive',
                style: TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9)),
            const SizedBox(height: 6),
            DarkInput(
                ctrl: widget.gdriveCtrl,
                hint: '1ABC_folder_id_xyz',
                readOnly: true),
            const SizedBox(height: 14),
            const Text('ID Thư mục tải video Reup',
                style: TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9)),
            const SizedBox(height: 6),
            DarkInput(
                ctrl: widget.reupDriveCtrl,
                hint: '1Oi3Rx1_nMfOIMh-L8iiJ1Z2d34YKJMxy',
                readOnly: true),
            const SizedBox(height: 8),
            const Text(
              'Để trống để dùng thư mục mặc định hoặc cấu hình backend.',
              style: TextStyle(color: kMuted, fontSize: 10.5),
            ),
            const SizedBox(height: 14),
            const Text('Đường dẫn file credentials.json',
                style: TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9)),
            const SizedBox(height: 4),
            const Text(
              'File OAuth2 — Google Cloud Console → APIs & Services → Credentials → '
              'OAuth 2.0 Client IDs → Desktop app → Tải JSON.',
              style: TextStyle(color: kTextDim, fontSize: 10.5),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                    child: DarkInput(
                        ctrl: widget.gdriveCredCtrl,
                        hint: 'C:\\path\\to\\credentials.json')),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    final res = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['json'],
                    );
                    if (res?.files.single.path != null) {
                      widget.gdriveCredCtrl.text = res!.files.single.path!;
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kTextDim,
                    side: const BorderSide(color: kBorder),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5)),
                  ),
                  child: const Text('Chọn', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ] else ...[
            const Text('Thư mục lưu kết quả',
                style: TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9)),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                    child: DarkInput(
                        ctrl: widget.localCtrl, hint: 'C:\\Videos\\output')),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath();
                    if (path != null) widget.localCtrl.text = path;
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kTextDim,
                    side: const BorderSide(color: kBorder),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5)),
                  ),
                  child: const Text('Chọn', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── Media section ─────────────────────────────────────────────────────────────

const _kPositions = {
  'top_left': 'Trên trái',
  'top_right': 'Trên phải',
  'center': 'Giữa',
  'bottom_left': 'Dưới trái',
  'bottom_right': 'Dưới phải',
};

class _MediaSection extends StatelessWidget {
  final TextEditingController musicFolderCtrl;
  final TextEditingController musicDriveCtrl;
  final TextEditingController logoPathCtrl;
  final TextEditingController logoDriveCtrl;
  final ApiService api;
  final int logoScale;
  final String logoPosition;
  final double logoOpacity;
  final ValueChanged<int> onScaleChanged;
  final ValueChanged<String> onPositionChanged;
  final ValueChanged<double> onOpacityChanged;

  const _MediaSection({
    required this.musicFolderCtrl,
    required this.musicDriveCtrl,
    required this.logoPathCtrl,
    required this.logoDriveCtrl,
    required this.api,
    required this.logoScale,
    required this.logoPosition,
    required this.logoOpacity,
    required this.onScaleChanged,
    required this.onPositionChanged,
    required this.onOpacityChanged,
  });

  Future<void> _showFilesList(BuildContext context, String folderId,
      {bool isLogo = false}) async {
    try {
      final items = await api.gdriveList(folderId);
      if (!context.mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text('Files in $folderId',
                style: const TextStyle(fontSize: 14)),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: items.map((f) {
                  final name = f['name'] as String? ?? 'untitled';
                  final link = f['webViewLink'] as String? ?? '';
                  return ListTile(
                    title: Text(name),
                    subtitle: Text(f['mimeType'] as String? ?? '',
                        style: const TextStyle(fontSize: 12)),
                    trailing: Wrap(spacing: 8, children: [
                      TextButton(
                        child: const Text('Copy link',
                            style: TextStyle(fontSize: 12)),
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Copied link for $name')));
                          if (isLogo) {
                            logoPathCtrl.text = link;
                          }
                        },
                      ),
                    ]),
                  );
                }).toList(),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Đóng')),
            ],
          );
        },
      );
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'CÀI ĐẶT MEDIA',
      actionWidget:
          const Icon(Icons.perm_media_outlined, size: 14, color: kMuted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Logo path ────────────────────────────────────────────────────────
          const Text(
            'Watermark Logo',
            style: TextStyle(
                color: kMuted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9),
          ),
          const SizedBox(height: 4),
          const Text('Định dạng PNG hoặc WEBP.',
              style: TextStyle(color: kTextDim, fontSize: 10.5)),
          const SizedBox(height: 6),

          const SizedBox(height: 8),
          const Text('Drive Logo Folder ID',
              style: TextStyle(
                  color: kMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                  child: DarkInput(
                      ctrl: logoDriveCtrl, hint: 'Drive folder ID for logos')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  final id = logoDriveCtrl.text.trim();
                  if (id.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Please enter folder ID')));
                    return;
                  }
                  await _showFilesList(context, id, isLogo: true);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                  elevation: 0,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('List', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  final id = logoDriveCtrl.text.trim();
                  if (id.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter folder ID')));
                    return;
                  }
                  final res = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['png', 'webp', 'jpg', 'jpeg']);
                  if (res?.files.single != null) {
                    final file = res!.files.single;
                    try {
                      final body = await api.gdriveUpload(file, id);
                      final link =
                          (body['link'] ?? body['meta']?['webViewLink'])
                                  ?.toString() ??
                              '';
                      if (link.isNotEmpty) logoPathCtrl.text = link;
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Uploaded: ${file.name}')));
                    } catch (e) {
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Upload error: $e')));
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                  elevation: 0,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Upload', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ── Logo scale ───────────────────────────────────────────────────────
          Row(
            children: [
              const Text(
                'Kích thước Logo (chiều rộng px)',
                style: TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: kInputBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: kBorder),
                ),
                child: Text('${logoScale}px',
                    style: const TextStyle(
                        color: kText, fontSize: 12, fontFamily: 'monospace')),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: kAccent,
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              overlayColor: kAccent.withValues(alpha: 0.1),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: logoScale.toDouble(),
              min: 50,
              max: 500,
              divisions: 45,
              onChanged: (v) => onScaleChanged(v.round()),
            ),
          ),
          const SizedBox(height: 14),

          // ── Logo position ────────────────────────────────────────────────────
          const Text(
            'Vị trí Logo',
            style: TextStyle(
                color: kMuted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _kPositions.entries.map((e) {
              final selected = logoPosition == e.key;
              return GestureDetector(
                onTap: () => onPositionChanged(e.key),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color:
                        selected ? kAccent.withValues(alpha: 0.15) : kInputBg,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color:
                          selected ? kAccent.withValues(alpha: 0.6) : kBorder,
                    ),
                  ),
                  child: Text(
                    e.value,
                    style: TextStyle(
                      color: selected ? kAccent : kTextDim,
                      fontSize: 11,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 14),

          // ── Logo opacity ─────────────────────────────────────────────────────
          Row(
            children: [
              const Text(
                'Độ mờ Logo',
                style: TextStyle(
                    color: kMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.9),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: kInputBg,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: kBorder),
                ),
                child: Text(
                  '${(logoOpacity * 100).round()}%',
                  style: const TextStyle(
                      color: kText, fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: kAccent,
              inactiveTrackColor: kBorder,
              thumbColor: kAccent,
              overlayColor: kAccent.withValues(alpha: 0.1),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              value: logoOpacity,
              min: 0.1,
              max: 1.0,
              divisions: 18,
              onChanged: onOpacityChanged,
            ),
          ),

          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Container(height: 1, color: kBorder),
          ),

          // ── Music folder ──────────────────────────────────────────────────
          const Text(
            'Thư mục nhạc nền',
            style: TextStyle(
                color: kMuted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.9),
          ),
          const SizedBox(height: 4),
          const Text(
            'Nhạc ngẫu nhiên cho mỗi video. Hỗ trợ MP3 · AAC · WAV · OGG · M4A · FLAC.',
            style: TextStyle(color: kTextDim, fontSize: 10.5),
          ),
          const SizedBox(height: 6),

          const SizedBox(height: 8),
          const Text('Drive Music Folder ID',
              style: TextStyle(
                  color: kMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                  child: DarkInput(
                      ctrl: musicDriveCtrl, hint: 'Drive folder ID for music')),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  final id = musicDriveCtrl.text.trim();
                  if (id.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Please enter folder ID')));
                    return;
                  }
                  try {
                    await _showFilesList(context, id, isLogo: false);
                  } catch (e) {
                    if (context.mounted)
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('Error: $e')));
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                  elevation: 0,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('List', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  final id = musicDriveCtrl.text.trim();
                  if (id.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter folder ID')));
                    return;
                  }
                  final res = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: [
                        'mp3',
                        'aac',
                        'wav',
                        'ogg',
                        'm4a',
                        'flac'
                      ]);
                  if (res?.files.single != null) {
                    final file = res!.files.single;
                    try {
                      await api.gdriveUpload(file, id);
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Uploaded: ${file.name}')));
                    } catch (e) {
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Upload error: $e')));
                    }
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5)),
                  elevation: 0,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Upload', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Lark section ──────────────────────────────────────────────────────────────

class _LarkSection extends StatelessWidget {
  final TextEditingController appIdCtrl;
  final TextEditingController appSecretCtrl;

  const _LarkSection({
    required this.appIdCtrl,
    required this.appSecretCtrl,
  });

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: 'LARK DATABASE',
      actionWidget:
          const Icon(Icons.open_in_new_rounded, size: 14, color: kMuted),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Info row
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: kAccent.withValues(alpha: 0.2)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Base đang kết nối',
                    style: TextStyle(
                        color: kMuted,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8)),
                const SizedBox(height: 4),
                const Text('langmodadh.sg.larksuite.com',
                    style: TextStyle(
                        color: kAccent, fontSize: 11, fontFamily: 'monospace')),
                const SizedBox(height: 6),
                _InfoRow(
                    label: 'Base ID', value: 'DLJfboBx0aKN5lsLV9tlGVVOgrd'),
                _InfoRow(label: 'Table ID', value: 'tblpyV8NmdLgNdnd'),
                _InfoRow(label: 'View ID', value: 'vewiEHKUSp'),
              ],
            ),
          ),
          const SizedBox(height: 14),

          const Text('App ID',
              style: TextStyle(
                  color: kMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9)),
          const SizedBox(height: 6),
          DarkInput(
              ctrl: appIdCtrl,
              hint: 'cli_xxxxxxxxxxxxxxxx',
              readOnly: true),
          const SizedBox(height: 12),

          const Text('App Secret',
              style: TextStyle(
                  color: kMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.9)),
          const SizedBox(height: 6),
          DarkInput(
              ctrl: appSecretCtrl,
              hint: '••••••••••••••••••••',
              readOnly: true),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(label,
                style: const TextStyle(color: kTextDim, fontSize: 10.5)),
          ),
          Text(value,
              style: const TextStyle(
                  color: kText, fontSize: 10.5, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}

class _SecretInput extends StatelessWidget {
  final TextEditingController ctrl;
  final bool obscure;
  final VoidCallback onToggle;
  const _SecretInput(
      {required this.ctrl, required this.obscure, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      obscureText: obscure,
      style: const TextStyle(color: kText, fontSize: 12),
      decoration: InputDecoration(
        hintText: '••••••••••••••••••••',
        hintStyle: const TextStyle(color: kMuted, fontSize: 12),
        filled: true,
        fillColor: kInputBg,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        suffixIcon: IconButton(
          icon: Icon(
              obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              size: 16,
              color: kTextDim),
          onPressed: onToggle,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: const BorderSide(color: kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(5),
          borderSide: BorderSide(color: Color.fromRGBO(37, 99, 235, 0.55)),
        ),
      ),
    );
  }
}

// Download section removed
