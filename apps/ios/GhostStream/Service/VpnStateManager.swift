// VpnStateManager — cross-process VPN state for the main app.
//
// Phase 8 additions:
//   • `statusFrame: StatusFrame` — rich stats frame read from snapshot.json
//     in the App Group container. Updated whenever the Darwin notification
//     fires (same cadence as the legacy `state` property).
//   • `state` is now derived from `statusFrame.state` when a snapshot is
//     available; falls back to legacy VpnStatePayload decoding otherwise.
//
// The Packet Tunnel Provider extension posts state updates via Darwin
// notifications + an App Group UserDefaults payload; this manager observes
// both and exposes an @Observable `state` for SwiftUI.

import Foundation
import Observation
// PhantomKit is the package that provides StatusFrame and ConnState.
// If PhantomKit is not yet linked to this target, replace the import with
// a local typealias or wait until the Xcode project is wired up.
// For now we import it conditionally; the compiler will fail fast if absent.
import PhantomKit

/// High-level VPN connection state rendered in the UI.
public enum VpnState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date, serverName: String)
    case disconnecting
    case error(String)
}

/// Serialisable form of `VpnState` used for cross-process handoff via
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

    public static func from(_ state: VpnState) -> VpnStatePayload {
        switch state {
        case .disconnected:
            return .init(kind: .disconnected)
        case .connecting:
            return .init(kind: .connecting)
        case .connected(let since, let name):
            return .init(kind: .connected, since: since.timeIntervalSince1970, serverName: name)
        case .disconnecting:
            return .init(kind: .disconnecting)
        case .error(let msg):
            return .init(kind: .error, error: msg)
        }
    }

    public var asState: VpnState {
        switch kind {
        case .disconnected:  return .disconnected
        case .connecting:    return .connecting
        case .connected:
            let date = Date(timeIntervalSince1970: since ?? Date().timeIntervalSince1970)
            return .connected(since: date, serverName: serverName ?? "")
        case .disconnecting: return .disconnecting
        case .error:         return .error(error ?? "unknown")
        }
    }
}

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
    /// lifetime of the process. Darwin notifications don't carry userInfo,
    /// so the closure is what actually threads the update into Swift.
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

/// Main-actor observable holder of the current VPN state. Syncs with the
/// Packet Tunnel Provider extension over Darwin notifications +
/// App Group UserDefaults.
@MainActor
@Observable
public final class VpnStateManager {

    /// Process-wide shared instance.
    public static let shared = VpnStateManager()

    /// Current VPN state (legacy enum). Derived from `statusFrame.state`
    /// when a PhantomKit snapshot is available; falls back to the
    /// VpnStatePayload in UserDefaults otherwise.
    public private(set) var state: VpnState = .disconnected

    /// Rich status frame from snapshot.json written by the extension.
    /// Starts as `.disconnected` until the first snapshot arrives.
    public private(set) var statusFrame: StatusFrame = .disconnected

    private let defaults: UserDefaults
    private let payloadKey = "vpn.state.v1"

    /// App Group container URL — used to locate snapshot.json.
    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ghoststream.vpn"
        )
    }

    private init() {
        self.defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")!
        self.loadPayload()
        self.loadSnapshot()
        self.observeDarwinNotifications()
    }

    /// Updates the state locally, writes a payload to App Group
    /// UserDefaults, and posts the Darwin notification so the other
    /// process can re-read.
    public func update(_ newState: VpnState) {
        state = newState
        writePayload(VpnStatePayload.from(newState))
        DarwinNotifications.post(DarwinNotifications.stateChanged)
    }

    // MARK: - Internal

    private func observeDarwinNotifications() {
        DarwinNotifications.observe(DarwinNotifications.stateChanged) { [weak self] in
            Task { @MainActor in
                self?.loadPayload()
                self?.loadSnapshot()
            }
        }
    }

    private func writePayload(_ payload: VpnStatePayload) {
        do {
            let data = try JSONEncoder().encode(payload)
            defaults.set(data, forKey: payloadKey)
        } catch {
            // Encoding VpnStatePayload is infallible in practice.
        }
    }

    private func loadPayload() {
        guard let data = defaults.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(VpnStatePayload.self, from: data)
        else { return }
        state = payload.asState
    }

    /// Reads snapshot.json from the App Group container and updates
    /// `statusFrame`. If the snapshot is present and parses successfully,
    /// `state` is also reconciled from it.
    private func loadSnapshot() {
        guard let url = containerURL?.appendingPathComponent("snapshot.json"),
              let data = try? Data(contentsOf: url),
              let frame = try? JSONDecoder().decode(StatusFrame.self, from: data)
        else { return }

        statusFrame = frame

        // Reconcile the legacy VpnState enum from the rich frame.
        switch frame.state {
        case .disconnected:
            state = .disconnected
        case .connecting:
            state = .connecting
        case .reconnecting:
            state = .connecting
        case .connected:
            let since = Date().addingTimeInterval(-Double(frame.sessionSecs))
            let serverName = frame.sni ?? frame.serverAddr ?? ""
            state = .connected(since: since, serverName: serverName)
        case .error:
            state = .error(frame.lastError ?? "unknown")
        }
    }
}
