import 'package:flutter/material.dart';
import '../constants/colors.dart';
import '../models/log_entry.dart';

class LogPanel extends StatefulWidget {
  final List<LogEntry> logs;
  final double progress;
  final bool running;
  const LogPanel({
    super.key,
    required this.logs,
    required this.progress,
    required this.running,
  });

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(covariant LogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.logs.length != oldWidget.logs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
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
    final now = DateTime.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

    return Container(
      color: kLogBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: const BoxDecoration(
              color: kSidebar,
              border: Border(bottom: BorderSide(color: kBorder)),
            ),
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: widget.running ? kAmber : kGreen,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 9),
                const Text(
                  'Nhật ký xử lý trực tiếp',
                  style: TextStyle(color: kText, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                const Text('UTF-8', style: TextStyle(color: kMuted, fontSize: 11)),
                const SizedBox(width: 16),
                Text(timeStr,
                    style: const TextStyle(
                        color: kMuted, fontSize: 11, fontFamily: 'monospace')),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              itemCount: widget.logs.length + 1,
              itemBuilder: (ctx, i) {
                if (i < widget.logs.length) return LogRow(entry: widget.logs[i]);
                return Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    children: [
                      Container(width: 22, height: 1, color: kMuted),
                      const SizedBox(width: 8),
                      const Text(
                        '  Hệ thống đang nghỉ  ',
                        style: TextStyle(
                            color: kMuted, fontSize: 11, fontStyle: FontStyle.italic),
                      ),
                      const SizedBox(width: 8),
                      Container(width: 22, height: 1, color: kMuted),
                    ],
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            decoration: const BoxDecoration(
              color: kSidebar,
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'TRẠNG THÁI ENGINE',
                      style: TextStyle(
                          color: kMuted, fontSize: 9,
                          fontWeight: FontWeight.w700, letterSpacing: 1.1),
                    ),
                    const Spacer(),
                    Text(
                      '${(widget.progress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(color: kMuted, fontSize: 9),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: widget.running ? widget.progress : 0,
                    minHeight: 3,
                    backgroundColor: kBorder,
                    valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class LogRow extends StatelessWidget {
  final LogEntry entry;
  const LogRow({super.key, required this.entry});

  Color get _dot => switch (entry.type) {
    LogType.success => kGreen,
    LogType.error   => kRed,
    LogType.warn    => kAmber,
    LogType.info    => kTextDim,
  };

  Color get _msg => switch (entry.type) {
    LogType.success => kGreen,
    LogType.error   => kRed,
    LogType.warn    => kAmber,
    LogType.info    => const Color(0xFFCBD5E1),
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 8),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(color: _dot, shape: BoxShape.circle),
            ),
          ),
          Text(
            entry.time,
            style: const TextStyle(
                color: kMuted, fontSize: 11, fontFamily: 'monospace'),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                  color: _msg, fontSize: 11.5, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}
