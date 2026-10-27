import XCTest
@testable import PhantomKit

final class AdminGatewayTests: XCTestCase {
    func testDerivesGatewayFromTunnelHostOctets() {
        XCTAssertEqual(AdminGateway.host(forTunAddr: "10.7.0.2/24"), "10.7.0.1")
        XCTAssertEqual(AdminGateway.host(forTunAddr: "10.42.9.77/24"), "10.42.9.1")
    }

    func testDerivationMatchesHostOctetsForWiderPrefixes() {
        XCTAssertEqual(AdminGateway.host(forTunAddr: "10.7.1.2/23"), "10.7.1.1")
    }

    func testInvalidTunnelAddressFallsBackToDefaultGateway() {
        XCTAssertEqual(AdminGateway.host(forTunAddr: "bad-profile"), AdminGateway.fallbackHost)
    }

    /// The server wraps the link in JSON; QR / Share / Copy need the bare `ghs://`.
    func testConnStringIsUnwrappedFromServerJson() {
        let link = "ghs://Y2VydA@vpn.example:443?sni=vpn.example&tun=10.7.0.5%2F24&v=1"
        XCTAssertEqual(AdminHttpClient.connString(fromBody: Data(#"{"conn_string":"\#(link)"}"#.utf8)), link)
        XCTAssertEqual(AdminHttpClient.connString(fromBody: Data("\(link)\n".utf8)), link)
        XCTAssertNil(AdminHttpClient.connString(fromBody: Data()))
    }

    /// `/api/me` is the only subscription source; an old server without
    /// `enabled` must not wipe the cached subscription.
    func testSelfInfoAppliesSubscriptionOnlyWhenServerSendsIt() throws {
        let decoder = JSONDecoder()
        var profile = VpnProfile(cachedExpiresAt: 42, cachedEnabled: true)

        let old = try decoder.decode(AdminSelfInfo.self, from: Data(#"{"name":"a","is_admin":true}"#.utf8))
        old.apply(to: &profile)
        XCTAssertEqual(profile.cachedIsAdmin, true)
        XCTAssertEqual(profile.cachedExpiresAt, 42)
        XCTAssertEqual(profile.cachedEnabled, true)

        let perpetual = try decoder.decode(
            AdminSelfInfo.self,
            from: Data(#"{"name":"a","is_admin":false,"expires_at":null,"enabled":false}"#.utf8)
        )
        perpetual.apply(to: &profile)
        XCTAssertEqual(profile.cachedIsAdmin, false)
        XCTAssertNil(profile.cachedExpiresAt)
        XCTAssertEqual(profile.cachedEnabled, false)
    }
}
