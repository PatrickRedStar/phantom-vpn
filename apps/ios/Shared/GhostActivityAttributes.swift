// Live Activity model, shared by the app (starts/updates/ends it) and the
// widget extension (renders it).

import ActivityKit
import Foundation

struct GhostActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var reconnecting: Bool
        /// Megabytes per second, one decimal.
        var rxMBps: Double
        var txMBps: Double
        var streamsUp: Int
        var streamsTotal: Int
    }

    var profileName: String
    /// Session start; the timer is rendered by the system from this date.
    var sessionStart: Date
}
