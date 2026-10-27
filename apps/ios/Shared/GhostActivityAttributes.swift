// Live Activity model, shared by the app (starts/updates/ends it) and the
// widget extension (renders it). Only the app can update the activity and it
// is suspended in the background, so no rates or stream counts here: the
// route is fixed for the session and the system draws the timer. Only the
// reconnecting flag can lag while the app sleeps.

import ActivityKit
import Foundation

struct GhostActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var reconnecting: Bool
    }

    var profileName: String
    /// Relay host when the session goes through the relay, nil = direct.
    var relayHost: String?
    /// Session start; the timer is rendered by the system from this date.
    var sessionStart: Date
}
