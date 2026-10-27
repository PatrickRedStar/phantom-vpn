import Foundation

/// Wall-clock start of a tunnel session for the UI timer
/// (`StatusFrame.sessionStartedAt`). The core's `session_secs` restarts on
/// every full reconnect and runs on a monotonic clock that stops while the
/// device sleeps, so the extension fixes the start once — on the first
/// `connected` after `startTunnel` — and keeps it through `reconnecting`
/// until the next start / stop (`reset()`).
public struct SessionClock {
    public private(set) var startedAt: Date?

    public init() {}

    public mutating func reset() {
        startedAt = nil
    }

    public mutating func stamp(_ frame: StatusFrame, now: Date = Date()) -> StatusFrame {
        if frame.state == .connected && startedAt == nil {
            startedAt = now
        }
        var stamped = frame
        stamped.sessionStartedAt = startedAt?.timeIntervalSince1970
        return stamped
    }
}
