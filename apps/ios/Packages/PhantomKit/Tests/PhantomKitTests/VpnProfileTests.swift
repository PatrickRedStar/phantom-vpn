// Regression coverage for `VpnProfile` sanitisation helpers — the two
// guard rails that keep client cert / key material out of system-level
// plaintext stores (NetworkExtension provider configuration plist on
// macOS, `NSUserDefaults` mirror on iOS).

import XCTest
@testable import PhantomKit

final class VpnProfileTests: XCTestCase {

    private func sampleProfile() -> VpnProfile {
        VpnProfile(
            id: "p1",
            name: "Test",
            serverAddr: "1.2.3.4:443",
            serverName: "cdn.example.com",
            insecure: false,
            certPem: "-----BEGIN CERTIFICATE-----\nABC\n-----END CERTIFICATE-----",
            keyPem: "-----BEGIN PRIVATE KEY-----\nXYZ\n-----END PRIVATE KEY-----",
            tunAddr: "10.7.0.2/24",
            dnsServers: ["1.1.1.1"],
            connString: "ghs://base64userinfo@1.2.3.4:443?sni=cdn.example.com&tun=10.7.0.2%2F24&v=1"
        )
    }

    /// profiles.json lives in App Group UserDefaults, readable by every
    /// member (the widget too): no PEM and no `ghs://` string — its
    /// userinfo is the base64 cert + private key. The tunnel rebuilds the
    /// string from the Keychain PEMs.
    func test_sanitizedForUserDefaults_dropsPemAndConnString() throws {
        let sanitized = sampleProfile().sanitizedForUserDefaults
        XCTAssertNil(sanitized.certPem)
        XCTAssertNil(sanitized.keyPem)
        XCTAssertNil(sanitized.connString)

        let json = String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self)
        XCTAssertFalse(json.contains("ghs://"))
        XCTAssertFalse(json.contains("PRIVATE KEY"))
    }

    /// What the extension does with a stored profile: Keychain PEMs back,
    /// no connString → ConnStringBuilder; relay swaps only the authority.
    func test_storedProfileRebuildsConnStringFromKeychainPems() throws {
        var stored = sampleProfile().sanitizedForUserDefaults
        stored.certPem = sampleProfile().certPem
        stored.keyPem = sampleProfile().keyPem
        stored.relayEnabled = true
        stored.relayAddr = "relay.example.com:443"

        let dialed = stored.withRelayEndpoint
        let conn = try XCTUnwrap(dialed.connString ?? ConnStringBuilder.build(from: dialed))
        XCTAssertTrue(conn.contains("@relay.example.com:443?sni=cdn.example.com&"))
    }

    /// `sanitizedForProviderConfiguration` is the macOS-specific guard.
    /// Whatever goes into a `NETunnelProviderProtocol.providerConfiguration`
    /// dict ends up world-readable under
    /// `/Library/Preferences/com.apple.networkextension*.plist`. The
    /// helper must scrub PEM **and** the original `ghs://` conn-string
    /// (its userinfo is base64-PEM).
    func test_sanitizedForProviderConfiguration_dropsAllSecrets() {
        let sanitized = sampleProfile().sanitizedForProviderConfiguration
        XCTAssertNil(sanitized.certPem)
        XCTAssertNil(sanitized.keyPem)
        XCTAssertNil(sanitized.connString,
                     "connString carries base64-PEM in userinfo — must not be persisted")

        // Sanity: non-secret fields survive — the extension still needs
        // them to resolve the profile and build NEPacketTunnelNetworkSettings.
        XCTAssertEqual(sanitized.id, "p1")
        XCTAssertEqual(sanitized.serverAddr, "1.2.3.4:443")
        XCTAssertEqual(sanitized.serverName, "cdn.example.com")
        XCTAssertEqual(sanitized.tunAddr, "10.7.0.2/24")
    }

    /// JSON-encoding a sanitised profile (the exact path
    /// `VpnTunnelController.installOnly` walks before stashing the blob
    /// into `providerConfiguration`) must not contain any of the PEM
    /// markers nor the original userinfo. This is the regression guard
    /// for the CRITICAL plist leak.
    func test_sanitizedForProviderConfiguration_jsonHasNoSecretsOnTheWire() throws {
        let sanitized = sampleProfile().sanitizedForProviderConfiguration
        let data = try JSONEncoder().encode(sanitized)
        let payload = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(payload.contains("BEGIN CERTIFICATE"),
                       "cert PEM leaked into provider configuration JSON")
        XCTAssertFalse(payload.contains("BEGIN PRIVATE KEY"),
                       "key PEM leaked into provider configuration JSON")
        XCTAssertFalse(payload.contains("ghs://"),
                       "ghs:// conn-string leaked into provider configuration JSON")
        XCTAssertFalse(payload.contains("base64userinfo"),
                       "userinfo body leaked into provider configuration JSON")
    }
}
