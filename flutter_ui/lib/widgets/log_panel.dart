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
          // ── Header ────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: kSidebar,
              border: Border(
                top: BorderSide(color: kBorder),
                bottom: BorderSide(color: kBorder),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: widget.running ? kAmber : kGreen,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (widget.running ? kAmber : kGreen).withValues(alpha: 0.4),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Nhật ký xử lý',
                  style: TextStyle(
                    color: kText,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  timeStr,
                  style: const TextStyle(
                    color: kMuted,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),

          // ── Log list ──────────────────────────────────────────────────────
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              itemCount: widget.logs.length + 1,
              itemBuilder: (ctx, i) {
                if (i < widget.logs.length) return LogRow(entry: widget.logs[i]);
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Container(width: 20, height: 1, color: kBorder),
                      const SizedBox(width: 8),
                      Text(
                        'Hệ thống đang chờ',
                        style: TextStyle(
                          color: kMuted,
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(width: 20, height: 1, color: kBorder),
                    ],
                  ),
                );
              },
            ),
          ),

          // ── Progress bar ──────────────────────────────────────────────────
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
                    Text(
                      widget.running ? 'ĐANG XỬ LÝ' : 'TRẠNG THÁI',
                      style: const TextStyle(
                        color: kTextDim,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(widget.progress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: kTextDim,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: widget.running ? widget.progress : 0,
                    minHeight: 6,
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

  Color get _dotColor => switch (entry.type) {
    LogType.success => kGreen,
    LogType.error   => kRed,
    LogType.warn    => kAmber,
    LogType.info    => kMuted,
  };

  Color get _msgColor => switch (entry.type) {
    LogType.success => kGreen,
    LogType.error   => kRed,
    LogType.warn    => kAmber,
    LogType.info    => kTextDim,
  };

  Color get _rowBg => switch (entry.type) {
    LogType.success => const Color(0xFFF0FDF4),
    LogType.error   => const Color(0xFFFFF1F2),
    LogType.warn    => const Color(0xFFFFFBEB),
    LogType.info    => Colors.transparent,
  };

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: _rowBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5, right: 8),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: _dotColor, shape: BoxShape.circle),
            ),
          ),
          Text(
            entry.time,
            style: const TextStyle(
              color: kMuted,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                color: _msgColor,
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
