import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';
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

  // DataScreen is kept mounted across navigation: disposing it would drop the
  // running jobs' log sockets and progress state. Offstage skips its layout and
  // paint while hidden; TickerMode stops its spinners from animating offstage.
  // SettingsScreen is still built fresh each visit so it re-reads config.
  Widget _buildContent() => Stack(
    fit: StackFit.expand,
    children: [
      TickerMode(
        enabled: _navIdx != 99,
        child: Offstage(offstage: _navIdx == 99, child: DataScreen(api: _api)),
      ),
      if (_navIdx == 99)
        SettingsScreen(api: _api, onBackendChanged: _saveBackendConfig),
    ],
  );
}
