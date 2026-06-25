import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
import '../services/update_service.dart';
import '../utils/open_url.dart';
import '../widgets/sidebar.dart';
import '../widgets/top_bar.dart';
import 'data_screen.dart';
import 'settings_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _navIdx = 1;
  final _api  = ApiService();

  @override
  void initState() {
    super.initState();
    _loadBackendConfig();
    Future.delayed(const Duration(seconds: 3), _checkUpdate);
  }

  Future<void> _checkUpdate() async {
    final update = await UpdateService.checkForUpdate();
    if (update == null || !mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Có bản cập nhật mới'),
        content: Text('Phiên bản ${update.version} đã sẵn sàng.\n'
            'Phiên bản hiện tại: ${UpdateService.currentVersion}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Để sau'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              openUrl(update.url);
            },
            child: const Text('Tải về'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadBackendConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final host  = prefs.getString('backend_host') ?? '127.0.0.1';
    var   port  = prefs.getInt('backend_port')    ?? 8765;
    if (port == 8000) port = 8765; // migrate old default
    setState(() {
      ApiService.host = host;
      ApiService.port = port;
    });
  }

  Future<void> _saveBackendConfig(String host, int port) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backend_host', host);
    await prefs.setInt('backend_port', port);
    setState(() {
      ApiService.host = host;
      ApiService.port = port;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Sidebar(navIdx: _navIdx, onNav: (i) => setState(() => _navIdx = i)),
          Expanded(
            child: Column(
              children: [
                const TopBar(),
                Expanded(child: _buildContent()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() => switch (_navIdx) {
    99  => SettingsScreen(api: _api, onBackendChanged: _saveBackendConfig),
    _   => DataScreen(api: _api),
  };
}
