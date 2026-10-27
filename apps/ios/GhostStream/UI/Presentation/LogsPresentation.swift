import Foundation
import PhantomKit

enum LogsPresentation {
    static func visibleLogs(
        allLogs: [LogFrame],
        filter: LogFilter,
        searchText: String
    ) -> [LogFrame] {
        let levelMinimum = filter.priority
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let filtered = allLogs.filter { frame in
            let levelAllowed = levelMinimum < 0 || LogFilter.priority(of: frame.level) >= levelMinimum
            guard levelAllowed else { return false }
            guard !needle.isEmpty else { return true }
            return frame.level.lowercased().contains(needle)
                || frame.msg.lowercased().contains(needle)
        }

        return Array(filtered.reversed())
    }

    /// Folds consecutive repeats (same level + message) into one line with
    /// a «×N» count, keeping the newest. Input and output are newest-first.
    static func collapsed(_ logs: [LogFrame]) -> [LogLine] {
        var out: [LogLine] = []
        for frame in logs {
            if let last = out.last, last.frame.level == frame.level, last.frame.msg == frame.msg {
                out[out.count - 1].count += 1
            } else {
                out.append(LogLine(frame: frame, count: 1))
            }
        }
        return out
    }
}

/// One rendered log line: the newest frame of a run of repeats.
struct LogLine: Identifiable, Equatable {
    let frame: LogFrame
    var count: Int
    var id: String { frame.id }
}
