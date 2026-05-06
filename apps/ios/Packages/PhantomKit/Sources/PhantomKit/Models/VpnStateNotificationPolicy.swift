import Foundation

public struct VpnStateNotification: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public enum VpnStateNotificationPolicy {
    public static func notification(
        previous: StatusFrame?,
        current: StatusFrame,
        enabled: Bool
    ) -> VpnStateNotification? {
        guard enabled, let previous, previous.state != current.state else { return nil }

        switch current.state {
        case .connected:
            return VpnStateNotification(
                title: "GhostStream connected",
                body: current.sni ?? current.serverAddr ?? "VPN tunnel is online"
            )
        case .reconnecting:
            let attempt = current.reconnectAttempt.map { "attempt \($0)" } ?? "attempt pending"
            let delay = current.reconnectNextDelaySecs.map { "\($0)s" } ?? "soon"
            return VpnStateNotification(
                title: "GhostStream reconnecting",
                body: "\(attempt) · retry in \(delay)"
            )
        case .disconnected:
            return VpnStateNotification(
                title: "GhostStream disconnected",
                body: "VPN tunnel is offline"
            )
        case .error:
            return VpnStateNotification(
                title: "GhostStream error",
                body: current.lastError ?? "VPN tunnel reported an error"
            )
        case .connecting:
            return nil
        }
    }
}
