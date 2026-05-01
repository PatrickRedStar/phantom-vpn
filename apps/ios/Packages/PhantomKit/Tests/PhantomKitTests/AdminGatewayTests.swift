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
}
