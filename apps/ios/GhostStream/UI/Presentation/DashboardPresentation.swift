import Foundation
import PhantomKit

enum DashboardTone: Equatable {
    case neutral
    case success
    case warning
    case danger
}

struct DashboardPresentationResult: Equatable {
    /// State headline («Передача», «Переподключение», …).
    let title: String
    let subtitle: String
    let primaryActionTitle: String
    let tone: DashboardTone
    let routeText: String
    let subscriptionText: String
}

enum DashboardPresentation {
    static func make(
        state: VpnState,
        activeProfileName: String?,
        timerText: String,
        routeIsDirect: Bool,
        subscriptionText: String?
    ) -> DashboardPresentationResult {
        let profileName = activeProfileName ?? L("native.dashboard.no.profile", "No profile")
        let route = routeIsDirect
            ? L("native.dashboard.direct", "Direct")
            : L("native.dashboard.relay", "Relay")
        let subscription = subscriptionText ?? L("native.dashboard.no.subscription", "No subscription data")

        switch state {
        case .connected:
            return DashboardPresentationResult(
                title: L("state_transmitting_verb", "Transmitting"),
                subtitle: "\(profileName) · \(timerText)",
                primaryActionTitle: L("action_disconnect", "Disconnect"),
                tone: .success,
                routeText: route,
                subscriptionText: subscription
            )
        case .reconnecting:
            return DashboardPresentationResult(
                title: L("native.dashboard.reconnecting", "Reconnecting"),
                subtitle: "\(profileName) · \(timerText)",
                primaryActionTitle: L("action_disconnect", "Disconnect"),
                tone: .warning,
                routeText: route,
                subscriptionText: subscription
            )
        case .connecting:
            return DashboardPresentationResult(
                title: L("native.dashboard.connecting", "Connecting"),
                subtitle: profileName,
                primaryActionTitle: L("native.dashboard.stop.attempt", "Stop attempt"),
                tone: .warning,
                routeText: route,
                subscriptionText: subscription
            )
        case .disconnecting:
            return DashboardPresentationResult(
                title: L("native.dashboard.disconnecting", "Disconnecting"),
                subtitle: profileName,
                primaryActionTitle: L("action_disconnect", "Disconnect"),
                tone: .warning,
                routeText: route,
                subscriptionText: subscription
            )
        case .error(let message):
            return DashboardPresentationResult(
                title: L("state_lost_verb", "Signal") + " " + L("state_signal_word", "lost"),
                subtitle: message,
                primaryActionTitle: L("action_retry", "Retry"),
                tone: .danger,
                routeText: route,
                subscriptionText: subscription
            )
        case .disconnected:
            return DashboardPresentationResult(
                title: L("native.dashboard.standby", "Standby"),
                subtitle: activeProfileName == nil ? L("native.dashboard.add.profile", "Add a profile to start VPN") : profileName,
                primaryActionTitle: L("action_connect", "Connect"),
                tone: .neutral,
                routeText: route,
                subscriptionText: subscription
            )
        }
    }

    /// `StatusFrame.rate_*_bps` is bits per second; the UI shows MB/s.
    static func megabytesPerSecond(bitsPerSecond: Double) -> Double {
        TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(bitsPerSecond) / 1_000_000
    }

    private static func L(_ key: String, _ fallback: String) -> String {
        AppStrings.localized(key, fallback: fallback)
    }
}
