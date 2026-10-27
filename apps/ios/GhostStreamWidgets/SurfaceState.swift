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
    var since: Date?
    var streamsUp = 0
    var streamsTotal = 0
    var profileName: String?

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

        struct Payload: Decodable { var kind: Kind; var since: Double? }
        if let data = defaults.data(forKey: "vpn.state.v1"),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            state.kind = payload.kind
            state.since = payload.since.map(Date.init(timeIntervalSince1970:))
        }

        struct Frame: Decodable { var streams_up: Int; var n_streams: Int }
        if let snapshot, let frame = try? JSONDecoder().decode(Frame.self, from: snapshot) {
            state.streamsUp = frame.streams_up
            state.streamsTotal = frame.n_streams
        }

        struct Profile: Decodable { var id: String; var name: String }
        if let data = defaults.data(forKey: "profiles.json"),
           let profiles = try? JSONDecoder().decode([Profile].self, from: data) {
            let activeId = defaults.string(forKey: "active_id")
            state.profileName = (profiles.first { $0.id == activeId } ?? profiles.first)?.name
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
