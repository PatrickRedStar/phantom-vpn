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
}
