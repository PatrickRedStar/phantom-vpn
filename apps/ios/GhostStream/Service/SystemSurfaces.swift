// SystemSurfaces — keeps the Live Activity, the home-screen widget and the
// Control Center toggle in step with VpnStateManager. Called on every state
// notification (VpnStateManager's Darwin observer).
//
// Live Activity: the app starts it when the tunnel is up (foreground, or
// inside a LiveActivityIntent), updates it while the app runs and ends it on
// disconnect. ActivityKit is driven only from the app process — the tunnel
// extension cannot see the app's activities. While the app is suspended the
// content freezes; the staleDate makes the view swap rates for the timer.

import ActivityKit
import Foundation
import PhantomKit
import WidgetKit

@MainActor
final class SystemSurfaces {
    static let shared = SystemSurfaces()

    private var lastKind: VpnStatePayload.Kind?
    private var lastActivityUpdate = Date.distantPast

    func sync() {
        let state = VpnStateManager.shared.state
        let kind = VpnStatePayload.from(state).kind
        if kind != lastKind {
            lastKind = kind
            WidgetCenter.shared.reloadAllTimelines()
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadAllControls()
            }
        }

        switch state {
        case .connected(let since, _):
            showLiveActivity(since: since, reconnecting: false)
        case .reconnecting(let since, _):
            showLiveActivity(since: since, reconnecting: true)
        case .disconnected, .error:
            Task { await endLiveActivity() }
        case .connecting, .disconnecting:
            break
        }
    }

    func endLiveActivity() async {
        for activity in Activity<GhostActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func showLiveActivity(since: Date, reconnecting: Bool) {
        let frame = VpnStateManager.shared.statusFrame
        let state = GhostActivityAttributes.ContentState(
            reconnecting: reconnecting,
            rxMBps: Self.megabytesPerSecond(frame.rateRxBps),
            txMBps: Self.megabytesPerSecond(frame.rateTxBps),
            streamsUp: Int(frame.streamsUp),
            streamsTotal: Int(frame.nStreams)
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(60))
        let now = Date()

        // `since` is recomputed from session_secs on every snapshot and
        // jitters by a second; a bigger gap means a new session.
        if let activity = Activity<GhostActivityAttributes>.activities.first,
           abs(activity.attributes.sessionStart.timeIntervalSince(since)) < 5 {
            let flipped = activity.content.state.reconnecting != reconnecting
            // Snapshots arrive every second; 5 s keeps the activity fresh
            // (staleDate) without hammering ActivityKit.
            guard flipped || now.timeIntervalSince(lastActivityUpdate) >= 5 else { return }
            lastActivityUpdate = now
            Task { await activity.update(content) }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = GhostActivityAttributes(
            profileName: ProfilesStore.shared.activeProfile?.name ?? "",
            sessionStart: since
        )
        // Fails in the background outside a LiveActivityIntent — the next
        // foreground sync starts it.
        guard let started = try? Activity.request(attributes: attributes, content: content) else { return }
        lastActivityUpdate = now
        for old in Activity<GhostActivityAttributes>.activities where old.id != started.id {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// StatusFrame rates are bits per second.
    private static func megabytesPerSecond(_ bitsPerSecond: Double) -> Double {
        (TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(bitsPerSecond) / 100_000).rounded() / 10
    }
}
