import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/log_entry.dart';
import 'vpn_state_provider.dart';

const _maxLogs = 50000;

const _levelPriority = {
  'error': 5,
  'warn': 4,
  'warning': 4,
  'info': 3,
  'debug': 2,
  'trace': 1,
};

int _priority(String level) => _levelPriority[level.toLowerCase()] ?? 0;

class LogsState {
  final List<LogEntry> allLogs;
  final String filterLevel;

  const LogsState({this.allLogs = const [], this.filterLevel = 'info'});

  List<LogEntry> get filteredLogs {
    final threshold = _priority(filterLevel);
    if (threshold <= 1) return allLogs;
    return allLogs.where((e) => _priority(e.level) >= threshold).toList();
  }

  LogsState copyWith({List<LogEntry>? allLogs, String? filterLevel}) => LogsState(
        allLogs: allLogs ?? this.allLogs,
        filterLevel: filterLevel ?? this.filterLevel,
      );
}

class LogsNotifier extends StateNotifier<LogsState> {
  final Ref _ref;
  StreamSubscription<List<LogEntry>>? _sub;

  LogsNotifier(this._ref) : super(const LogsState()) {
    _sub = _ref.read(vpnBridgeProvider).logsStream.listen(_onBatch);
  }

  void _onBatch(List<LogEntry> batch) {
    if (batch.isEmpty) return;
    final merged = [...state.allLogs, ...batch];
    final trimmed = merged.length > _maxLogs
        ? merged.sublist(merged.length - _maxLogs)
        : merged;
    state = state.copyWith(allLogs: trimmed);
  }

  void setFilter(String level) {
    state = state.copyWith(filterLevel: level);
  }

  void clear() {
    state = state.copyWith(allLogs: []);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final logsProvider = StateNotifierProvider<LogsNotifier, LogsState>((ref) {
  return LogsNotifier(ref);
});

final filteredLogsProvider = Provider<List<LogEntry>>((ref) {
  return ref.watch(logsProvider).filteredLogs;
});
