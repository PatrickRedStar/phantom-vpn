import Foundation
import PhantomKit

enum DashboardTone: Equatable {
    case neutral
    case success
    case warning
    case danger
}

struct DashboardPresentationResult: Equatable {
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
        let profileName = activeProfileName ?? "No profile"
        let route = routeIsDirect ? "Direct" : "Relay"
        let subscription = subscriptionText ?? "No subscription data"

        switch state {
        case .connected:
            return DashboardPresentationResult(
                title: "Protected",
                subtitle: "\(profileName) · \(timerText)",
                primaryActionTitle: "Disconnect",
                tone: .success,
                routeText: route,
                subscriptionText: subscription
            )
        case .connecting:
            return DashboardPresentationResult(
                title: "Connecting",
                subtitle: profileName,
                primaryActionTitle: "Stop attempt",
                tone: .warning,
                routeText: route,
                subscriptionText: subscription
            )
        case .disconnecting:
            return DashboardPresentationResult(
                title: "Disconnecting",
                subtitle: profileName,
                primaryActionTitle: "Disconnect",
                tone: .warning,
                routeText: route,
                subscriptionText: subscription
            )
        case .error(let message):
            return DashboardPresentationResult(
                title: "Connection failed",
                subtitle: message,
                primaryActionTitle: "Retry",
                tone: .danger,
                routeText: route,
                subscriptionText: subscription
            )
        case .disconnected:
            return DashboardPresentationResult(
                title: "Standby",
                subtitle: activeProfileName == nil ? "Add a profile to start VPN" : profileName,
                primaryActionTitle: "Connect",
                tone: .neutral,
                routeText: route,
                subscriptionText: subscription
            )
        }
    }
}
