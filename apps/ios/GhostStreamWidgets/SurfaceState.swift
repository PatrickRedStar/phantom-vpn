// VPN state for the widget and the Control Center toggle, read from the App
// Group the app and the tunnel extension already write: `vpn.state.v1`
// (VpnStatePayload), `snapshot.json` (StatusFrame), `profiles.json` +
// `active_id` (ProfilesStore). Also compiled into GhostStreamTests, which
// checks these keys against PhantomKit's real encoders.

import Foundation

struct SurfaceState {
    /// Raw values match VpnStatePayload.Kind and the "state.*" string keys.
    enum Kind: String, Decodable {
        case disconnected, connecting, connected, reconnecting, disconnecting, error
    }

    var kind: Kind = .disconnected
    /// Session start: `session_started_at` when the tunnel writes it, else
    /// the payload's `since`.
    var since: Date?
    var profileName: String?
    /// Relay host of the active profile, nil = direct.
    var relayHost: String?

    var isOn: Bool { kind == .connected || kind == .reconnecting || kind == .connecting }

    private static let group = "group.com.ghoststream.client"

    static func load() -> SurfaceState {
        guard let defaults = UserDefaults(suiteName: group) else { return SurfaceState() }
        let snapshot = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
            .flatMap { try? Data(contentsOf: $0.appendingPathComponent("snapshot.json")) }
        return decode(defaults: defaults, snapshot: snapshot)
    }

    static func decode(defaults: UserDefaults, snapshot: Data?) -> SurfaceState {
        var state = SurfaceState()

        struct Payload: Decodable { var kind: Kind; var since: Double?; var session_started_at: Double? }
        struct Frame: Decodable { var session_started_at: Double? }
        if let data = defaults.data(forKey: "vpn.state.v1"),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            state.kind = payload.kind
            let frameStart = snapshot.flatMap { try? JSONDecoder().decode(Frame.self, from: $0) }?.session_started_at
            state.since = (payload.session_started_at ?? frameStart ?? payload.since)
                .map(Date.init(timeIntervalSince1970:))
        }

        struct Profile: Decodable {
            var id: String
            var name: String
            var serverAddr: String?
            var relayEnabled: Bool?
            var relayAddr: String?
        }
        if let data = defaults.data(forKey: "profiles.json"),
           let profiles = try? JSONDecoder().decode([Profile].self, from: data) {
            let activeId = defaults.string(forKey: "active_id")
            let active = profiles.first { $0.id == activeId } ?? profiles.first
            state.profileName = active?.name
            // Same rule as VpnProfile.relayActive; the port is dropped.
            if let active, active.relayEnabled == true,
               let relay = active.relayAddr?.trimmingCharacters(in: .whitespaces),
               !relay.isEmpty, relay != active.serverAddr {
                if let colon = relay.lastIndex(of: ":"), UInt16(relay[relay.index(after: colon)...]) != nil {
                    state.relayHost = String(relay[..<colon])
                } else {
                    state.relayHost = relay
                }
            }
        }
        return state
    }

    /// Language chosen in the app's settings, so the widget speaks the same.
    static var locale: Locale {
        guard let code = UserDefaults(suiteName: group)?.string(forKey: "language_override"),
              !code.isEmpty, code != "system"
        else { return .autoupdatingCurrent }
        return Locale(identifier: code)
    }
}
