// SharedState — cross-process types shared by the host app and the
// PacketTunnelProvider extension for state handoff via App Group
// UserDefaults + Darwin notifications.

import Foundation

// MARK: - VpnStatePayload

/// Serialisable form of the VPN state used for cross-process handoff via
/// App Group UserDefaults. Keeps the main-app / extension coupling to a
/// DTO rather than a shared enum type.
public struct VpnStatePayload: Codable, Equatable {
    public enum Kind: String, Codable {
        case disconnected, connecting, connected, disconnecting, error
    }
    public var kind: Kind
    public var since: Double?
    public var serverName: String?
    public var error: String?

    public init(kind: Kind, since: Double? = nil, serverName: String? = nil, error: String? = nil) {
        self.kind = kind
        self.since = since
        self.serverName = serverName
        self.error = error
    }
}

// MARK: - DarwinNotifications

/// Namespace for Darwin notification helpers used to coordinate the main
/// app and the Packet Tunnel Provider extension (which are separate
/// processes and cannot share memory).
public enum DarwinNotifications {
    /// Notification name broadcast when the extension updates VPN state.
    public static let stateChanged = "com.ghoststream.vpn.stateChanged"

    /// Posts a Darwin notification with `name`. Safe to call from any
    /// thread.
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

    /// Observer-holder class to retain the trailing closure across the
    /// lifetime of the process.
    final class ObserverBox {
        let callback: () -> Void
        init(_ cb: @escaping () -> Void) { self.callback = cb }
    }

    /// Retain root for observer boxes. Intentionally leaked for the
    /// lifetime of the process.
    nonisolated(unsafe) private static var observers: [ObserverBox] = []

    /// Registers `cb` to run whenever a Darwin notification named `name`
    /// is posted. `cb` is invoked on an arbitrary thread — hop to the
    /// main actor if you touch UI state.
    public static func observe(_ name: String, _ cb: @escaping () -> Void) {
        let box = ObserverBox(cb)
        observers.append(box)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let trampoline: CFNotificationCallback = { _, ctx, _, _, _ in
            guard let ctx else { return }
            let box = Unmanaged<ObserverBox>.fromOpaque(ctx).takeUnretainedValue()
            box.callback()
        }
        CFNotificationCenterAddObserver(
            center,
            ctx,
            trampoline,
            name as CFString,
            nil,
            .deliverImmediately
        )
    }
}
