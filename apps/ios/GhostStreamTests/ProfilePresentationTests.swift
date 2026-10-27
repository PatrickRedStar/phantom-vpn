import XCTest
import NetworkExtension
import Security
import PhantomKit
@testable import GhostStream

final class ProfilePresentationTests: XCTestCase {
    @MainActor
    func testAdminGatewayIsDerivedFromProfileTunAddress() {
        let profile = VpnProfile(tunAddr: "10.42.9.77/24")

        XCTAssertEqual(
            ProfileEntitlementRefresher.adminBaseURL(for: profile)?.absoluteString,
            "https://10.42.9.1:8080"
        )
    }

    @MainActor
    func testPerpetualSubscriptionTextRequiresFetchedProfileState() {
        XCTAssertNil(ProfileEntitlementRefresher.subscriptionText(for: VpnProfile()))

        let profile = VpnProfile(cachedEnabled: true)
        XCTAssertEqual(
            ProfileEntitlementRefresher.subscriptionText(for: profile),
            AppStrings.localized("dashboard.subscription.unlimited")
        )
    }

    func testAdminStatusDecodesCurrentServerPayload() throws {
        let json = Data("""
        {"uptime_secs": 42, "sessions_active": 3, "server_addr": "vpn.example:443", "exit_ip": "203.0.113.7"}
        """.utf8)

        let status = try JSONDecoder().decode(AdminStatus.self, from: json)

        XCTAssertEqual(status.uptimeSecs, 42)
        XCTAssertEqual(status.activeSessions, 3)
        XCTAssertEqual(status.serverAddr, "vpn.example:443")
        XCTAssertEqual(status.serverIp, "203.0.113.7")
        XCTAssertEqual(status.exitIp, "203.0.113.7")
    }

    @MainActor
    func testEntitlementRefreshCanUseSystemVpnStatusWhenAppStateIsStale() {
        XCTAssertTrue(
            ProfileEntitlementRefresher.shouldAttemptRefresh(
                appState: .disconnected,
                systemStatus: .connected
            )
        )
        XCTAssertTrue(
            ProfileEntitlementRefresher.shouldAttemptRefresh(
                appState: .connecting,
                systemStatus: nil
            )
        )
        XCTAssertFalse(
            ProfileEntitlementRefresher.shouldAttemptRefresh(
                appState: .disconnecting,
                systemStatus: .connected
            )
        )
        XCTAssertFalse(
            ProfileEntitlementRefresher.shouldAttemptRefresh(
                appState: .disconnected,
                systemStatus: .disconnected
            )
        )
    }

    @MainActor
    func testEcP256Pkcs8KeyMaterialCanCreateSecKey() throws {
        let der = try XCTUnwrap(Self.decodePem(Self.ecP256Pkcs8FixturePem))
        let (keyType, keyData, keySize) = try AdminIdentityTestSupport.inspectPkcs8(der)

        XCTAssertEqual(keyType, kSecAttrKeyTypeECSECPrimeRandom)
        XCTAssertEqual(keySize, 256)

        var attrs: [CFString: Any] = [
            kSecAttrKeyType: keyType,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        if let keySize {
            attrs[kSecAttrKeySizeInBits] = keySize
        }

        var error: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error)

        XCTAssertNotNil(
            key,
            "Expected EC P-256 PKCS#8 material to be accepted by SecKeyCreateWithData, got \(String(describing: error?.takeRetainedValue()))"
        )
    }

    private static func decodePem(_ pem: String) -> Data? {
        let stripped = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .replacingOccurrences(of: " ", with: "")
        return Data(base64Encoded: stripped)
    }

    // Throwaway test-only EC P-256 PKCS#8 key generated for Security framework
    // regression coverage. It is not used by the app at runtime.
    private static let ecP256Pkcs8FixturePem = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgtqzcu4JSUOqzDpPw
    SARwnTn4m0+3y6+Kvse9VGoRJgOhRANCAATgagfJNVRiPobDV0oGQnsluuhZj58P
    QlFUmf1+dpTWBcSNRJJtLDza5KJOv4/TmUI83eNklerbagyhaMTPy7II
    -----END PRIVATE KEY-----
    """
}
