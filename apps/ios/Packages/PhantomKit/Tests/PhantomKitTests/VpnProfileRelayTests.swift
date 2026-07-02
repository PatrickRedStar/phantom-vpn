import XCTest
@testable import PhantomKit

/// Relay hop semantics on `VpnProfile`:
/// `effectiveServerAddr` is what the transport dials; `serverName` (SNI)
/// must never be affected by the relay — passthrough requires the exit's SNI.
final class VpnProfileRelayTests: XCTestCase {

    private func profile(
        relayEnabled: Bool? = nil,
        relayAddr: String? = nil
    ) -> VpnProfile {
        VpnProfile(
            name: "t",
            serverAddr: "1.2.3.4:443",
            serverName: "tls.exit.example.com",
            tunAddr: "10.7.0.2/24",
            relayEnabled: relayEnabled,
            relayAddr: relayAddr
        )
    }

    // MARK: - effectiveServerAddr

    func testDirectByDefault() {
        let p = profile()
        XCTAssertEqual(p.effectiveServerAddr, "1.2.3.4:443")
        XCTAssertFalse(p.relayActive)
    }

    func testRelayEnabledSubstitutesAddr() {
        let p = profile(relayEnabled: true, relayAddr: "5.6.7.8:443")
        XCTAssertEqual(p.effectiveServerAddr, "5.6.7.8:443")
        XCTAssertTrue(p.relayActive)
        // SNI stays the exit's name.
        XCTAssertEqual(p.serverName, "tls.exit.example.com")
    }

    func testRelayEnabledButEmptyAddrFallsBackToDirect() {
        XCTAssertEqual(profile(relayEnabled: true, relayAddr: nil).effectiveServerAddr, "1.2.3.4:443")
        XCTAssertEqual(profile(relayEnabled: true, relayAddr: "").effectiveServerAddr, "1.2.3.4:443")
        XCTAssertEqual(profile(relayEnabled: true, relayAddr: "   ").effectiveServerAddr, "1.2.3.4:443")
        XCTAssertFalse(profile(relayEnabled: true, relayAddr: "").relayActive)
    }

    func testRelayDisabledIgnoresAddr() {
        let p = profile(relayEnabled: false, relayAddr: "5.6.7.8:443")
        XCTAssertEqual(p.effectiveServerAddr, "1.2.3.4:443")
        XCTAssertFalse(p.relayActive)
    }

    func testRelayAddrIsTrimmed() {
        let p = profile(relayEnabled: true, relayAddr: " 5.6.7.8:443\n")
        XCTAssertEqual(p.effectiveServerAddr, "5.6.7.8:443")
    }

    // MARK: - Codable back-compat

    /// Profiles persisted before the relay fields existed must decode
    /// without error and behave as direct connections.
    func testDecodeLegacyProfileWithoutRelayFields() throws {
        let legacy = """
        {"id":"x","name":"old","serverAddr":"1.2.3.4:443",
         "serverName":"sni.example.com","insecure":false,"tunAddr":"10.7.0.2/24"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(VpnProfile.self, from: legacy)
        XCTAssertNil(p.relayEnabled)
        XCTAssertNil(p.relayAddr)
        XCTAssertEqual(p.effectiveServerAddr, "1.2.3.4:443")
    }

    func testRelayFieldsRoundTrip() throws {
        let p = profile(relayEnabled: true, relayAddr: "5.6.7.8:443")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(VpnProfile.self, from: data)
        XCTAssertEqual(back.relayEnabled, true)
        XCTAssertEqual(back.relayAddr, "5.6.7.8:443")
        XCTAssertEqual(back.effectiveServerAddr, "5.6.7.8:443")
    }

    /// Relay fields ride along both sanitized copies — they are not secrets,
    /// and the provider needs them absent (substitution happens host-side,
    /// the provider only ever sees the already-substituted `serverAddr`).
    func testSanitizedCopiesPreserveRelayFields() {
        let p = profile(relayEnabled: true, relayAddr: "5.6.7.8:443")
        XCTAssertEqual(p.sanitizedForUserDefaults.relayAddr, "5.6.7.8:443")
        XCTAssertEqual(p.sanitizedForProviderConfiguration.relayEnabled, true)
    }
}
