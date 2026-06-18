enum LogType { info, success, error, warn }

class LogEntry {
  final String time;
  final String message;
  final LogType type;

  const LogEntry(this.time, this.message, this.type);

  factory LogEntry.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String? ?? 'info';
    final type = switch (typeStr) {
      'success' => LogType.success,
      'error'   => LogType.error,
      'warn'    => LogType.warn,
      _         => LogType.info,
    };
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    return LogEntry('[$h:$m:$s]', json['message'] as String? ?? '', type);
  }
}
