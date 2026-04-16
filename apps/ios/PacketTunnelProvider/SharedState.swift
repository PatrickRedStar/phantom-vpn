// SharedState — extension-side duplicate of the VPN-state DTO + Darwin
// notification poster. The extension does not observe, only posts —
// the main app's VpnStateManager does the observing.

import Foundation

/// Kind of VPN state — mirrors `VpnStatePayload.Kind` in the main app.
public enum VpnStateKind: String, Codable {
    case disconnected, connecting, connected, disconnecting, error
}

/// Cross-process payload written to the App Group UserDefaults at key
/// `vpn.state.v1`. Must stay structurally identical to the main app's
/// `VpnStatePayload`.
public struct VpnStatePayload: Codable {
    public var kind: VpnStateKind
    public var since: Double?
    public var serverName: String?
    public var error: String?

    public init(
        kind: VpnStateKind,
        since: Double? = nil,
        serverName: String? = nil,
        error: String? = nil
    ) {
        self.kind = kind
        self.since = since
        self.serverName = serverName
        self.error = error
    }
}

/// Darwin notification names shared with the main app.
public enum DarwinNotifications {
    /// Posted whenever the extension updates the VPN state payload.
    public static let stateChanged = "com.ghoststream.vpn.stateChanged"

    /// Posts a Darwin notification by name.
    public static func post(_ name: String) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Writes `payload` to the shared App Group UserDefaults under key
/// `vpn.state.v1` and posts the Darwin notification. No-op (silent) if
/// JSON encoding fails — VpnStatePayload is infallible in practice.
public func writeVpnState(_ payload: VpnStatePayload) {
    guard let defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn") else { return }
    if let data = try? JSONEncoder().encode(payload) {
        defaults.set(data, forKey: "vpn.state.v1")
    }
    DarwinNotifications.post(DarwinNotifications.stateChanged)
}
