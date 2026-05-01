import Foundation

/// Coalesces high-frequency tunnel telemetry before crossing the extension/app
/// process boundary. State changes stay immediate; steady connected metrics are
/// allowed through at a lower cadence.
public struct StatusBroadcastGate {
    private let minInterval: TimeInterval
    private var lastBroadcastAt: TimeInterval?
    private var lastState: ConnState?
    private var lastError: String?
    private var lastReconnectAttempt: UInt32?
    private var lastReconnectNextDelaySecs: UInt32?

    public init(minInterval: TimeInterval = 1.0) {
        self.minInterval = minInterval
    }

    public mutating func shouldBroadcast(_ frame: StatusFrame, now: TimeInterval) -> Bool {
        if isStateBoundary(frame) {
            record(frame, now: now)
            return true
        }

        guard let lastBroadcastAt else {
            record(frame, now: now)
            return true
        }

        guard now - lastBroadcastAt >= minInterval else {
            return false
        }

        record(frame, now: now)
        return true
    }

    public mutating func reset() {
        lastBroadcastAt = nil
        lastState = nil
        lastError = nil
        lastReconnectAttempt = nil
        lastReconnectNextDelaySecs = nil
    }

    private func isStateBoundary(_ frame: StatusFrame) -> Bool {
        lastState != frame.state
            || lastError != frame.lastError
            || lastReconnectAttempt != frame.reconnectAttempt
            || lastReconnectNextDelaySecs != frame.reconnectNextDelaySecs
    }

    private mutating func record(_ frame: StatusFrame, now: TimeInterval) {
        lastBroadcastAt = now
        lastState = frame.state
        lastError = frame.lastError
        lastReconnectAttempt = frame.reconnectAttempt
        lastReconnectNextDelaySecs = frame.reconnectNextDelaySecs
    }
}
