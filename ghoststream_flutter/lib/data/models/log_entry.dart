class LogEntry {
  final int seq;
  final String timestamp;
  final String level;
  final String message;

  const LogEntry({
    required this.seq,
    required this.timestamp,
    required this.level,
    required this.message,
  });

  factory LogEntry.fromJson(Map<String, dynamic> json) => LogEntry(
    seq: json['seq'] as int? ?? 0,
    timestamp: json['timestamp'] as String? ?? '',
    level: json['level'] as String? ?? 'info',
    message: json['message'] as String? ?? json['msg'] as String? ?? '',
  );
}
