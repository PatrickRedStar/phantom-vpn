// SystemSurfaces — keeps the Live Activity, the home-screen widget and the
// Control Center toggle in step with VpnStateManager. Called on every state
// notification (VpnStateManager's Darwin observer).
//
// Live Activity: the app starts it when the tunnel is up (foreground, or
// inside a LiveActivityIntent), updates it while the app runs and ends it on
// disconnect. ActivityKit is driven only from the app process — the tunnel
// extension cannot see the app's activities. While the app is suspended the
// content freezes, so it carries nothing that changes on its own (no rates).
//
// Widget / control labels (profile name, route, language) are reloaded when
// they change too — created at launch (GhostStreamApp) for that.

import ActivityKit
import Foundation
import Observation
import PhantomKit
import WidgetKit

@MainActor
final class SystemSurfaces {
    static let shared = SystemSurfaces()

    private var lastKind: VpnStatePayload.Kind?
    private var lastLabel: String?

    private init() {
        observeLabel()
    }

    func sync() {
        let state = VpnStateManager.shared.state
        let kind = VpnStatePayload.from(state).kind
        if kind != lastKind {
            lastKind = kind
            reloadWidgets()
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

    private func reloadWidgets() {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
    }

    /// The control shows the active profile's name, the widget also its
    /// route, both in the app's language — none of that is a state change.
    private func observeLabel() {
        let label = withObservationTracking {
            let profile = ProfilesStore.shared.activeProfile
            return [profile?.name, profile?.effectiveServerAddr, PreferencesStore.shared.languageOverride]
                .map { $0 ?? "" }.joined(separator: "|")
        } onChange: {
            Task { @MainActor in SystemSurfaces.shared.observeLabel() }
        }
        if let lastLabel, lastLabel != label { reloadWidgets() }
        lastLabel = label
    }

    /// Tunnel session start the extension writes as `session_started_at`
    /// (unix seconds) into the state payload or the snapshot; nil from an
    /// extension that doesn't write it yet.
    static func sessionStartedAt() -> Date? {
        struct Session: Decodable { var session_started_at: Double? }
        let payload = UserDefaults(suiteName: SharedKeys.appGroup)?.data(forKey: "vpn.state.v1")
        let snapshot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedKeys.appGroup)
            .flatMap { try? Data(contentsOf: $0.appendingPathComponent("snapshot.json")) }
        for data in [payload, snapshot].compactMap({ $0 }) {
            if let t = (try? JSONDecoder().decode(Session.self, from: data))?.session_started_at {
                return Date(timeIntervalSince1970: t)
            }
        }
        return nil
    }

    func endLiveActivity() async {
        for activity in Activity<GhostActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func showLiveActivity(since: Date, reconnecting: Bool) {
        // Settings → «Dynamic Island» off: no activity, end a running one.
        guard PreferencesStore.shared.liveActivity else {
            Task { await endLiveActivity() }
            return
        }
        let content = ActivityContent(
            state: GhostActivityAttributes.ContentState(reconnecting: reconnecting),
            staleDate: nil
        )

        // One activity per tunnel session, keyed by the tunnel's own
        // `session_started_at`. Without it (older extension) by `since`,
        // recomputed from session_secs on every snapshot: it jitters by a
        // second, a bigger gap means a new session. Ended / dismissed
        // activities linger in `activities` and can't be updated.
        let started = Self.sessionStartedAt()
        let sessionStart = started ?? since
        let tolerance: TimeInterval = started == nil ? 5 : 1
        if let activity = Activity<GhostActivityAttributes>.activities.first(where: {
            ($0.activityState == .active || $0.activityState == .stale)
                && abs($0.attributes.sessionStart.timeIntervalSince(sessionStart)) < tolerance
        }) {
            if activity.content.state.reconnecting != reconnecting {
                Task { await activity.update(content) }
            }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let profile = ProfilesStore.shared.activeProfile
        let relay = profile.flatMap { $0.relayActive ? $0.effectiveServerAddr : nil }
        let attributes = GhostActivityAttributes(
            profileName: profile?.name ?? "",
            relayHost: relay.map { SettingsViewModel.parseHostPort($0)?.0 ?? $0 },
            sessionStart: sessionStart
        )
        // Fails in the background outside a LiveActivityIntent — the next
        // foreground sync starts it.
        guard let started = try? Activity.request(attributes: attributes, content: content) else { return }
        for old in Activity<GhostActivityAttributes>.activities where old.id != started.id {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
