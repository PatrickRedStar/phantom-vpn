import XCTest
import PhantomKit

/// The widget extension doesn't link PhantomKit and decodes the App Group by
/// hand; this pins its keys to what the app and the tunnel actually write.
final class SurfaceStateTests: XCTestCase {
    func testReadsWhatAppAndTunnelWrite() throws {
        let suite = "SurfaceStateTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let payload = VpnStatePayload(kind: .reconnecting, since: 1_000, serverName: "nl")
        defaults.set(try JSONEncoder().encode(payload), forKey: "vpn.state.v1")
        let profiles = [
            VpnProfile(id: "a", name: "alpha"),
            VpnProfile(id: "g", name: "galaxy", serverAddr: "exit:8443", relayEnabled: true, relayAddr: "relay.example:443"),
        ]
        defaults.set(try JSONEncoder().encode(profiles.map(\.sanitizedForUserDefaults)), forKey: "profiles.json")
        defaults.set("g", forKey: "active_id")
        var frame = StatusFrame.disconnected
        frame.state = .reconnecting

        let state = SurfaceState.decode(defaults: defaults, snapshot: try JSONEncoder().encode(frame))

        XCTAssertEqual(state.kind, .reconnecting)
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.since, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(state.profileName, "galaxy")
        XCTAssertEqual(state.relayHost, "relay.example")
    }

    /// The tunnel's wall-clock session start wins over the recomputed `since`.
    func testSessionStartedAtIsTheTimerOrigin() throws {
        let suite = "SurfaceStateTests.session"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"{"kind":"connected","since":1000,"session_started_at":900}"#.utf8), forKey: "vpn.state.v1")

        let state = SurfaceState.decode(defaults: defaults, snapshot: nil)

        XCTAssertEqual(state.since, Date(timeIntervalSince1970: 900))
        XCTAssertNil(state.relayHost)
    }

    func testEmptyGroupIsDisconnected() throws {
        let suite = "SurfaceStateTests.empty"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let state = SurfaceState.decode(defaults: defaults, snapshot: nil)

        XCTAssertEqual(state.kind, .disconnected)
        XCTAssertFalse(state.isOn)
        XCTAssertNil(state.profileName)
    }
}
