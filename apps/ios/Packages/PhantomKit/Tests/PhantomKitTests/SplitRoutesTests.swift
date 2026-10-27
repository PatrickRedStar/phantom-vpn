import XCTest
@testable import PhantomKit

/// Contract of `phantom_compute_vpn_routes` the iOS provider relies on:
/// an oversized list yields `[]` (the provider then takes the full tunnel),
/// never a partial table.
final class SplitRoutesTests: XCTestCase {

    /// `count` non-adjacent /24s from 1.0.0.0 up — nothing aggregates.
    private func directList(_ count: Int) -> String {
        (0..<count).map { i -> String in
            let n = UInt32(0x0100_0000) + UInt32(i) * 512
            return "\(n >> 24).\((n >> 16) & 0xFF).\((n >> 8) & 0xFF).0/24"
        }.joined(separator: "\n")
    }

    /// geoip ru is ~12.9k IPv4 blocks (~200 KB): exact prefixes fit the
    /// input cap and come back within the core's 8000-route budget.
    func testCountrySizedExactListFitsBudget() {
        let text = directList(13_000)
        XCTAssertLessThan(text.utf8.count, 262_144)
        let routes = PhantomBridge.computeVpnRoutes(directCidrs: text)
        XCTAssertFalse(routes.isEmpty)
        XCTAssertLessThanOrEqual(routes.count, 8_000)
    }

    func testListOverInputCapYieldsNoRoutes() {
        let text = directList(20_000)
        XCTAssertGreaterThan(text.utf8.count, 262_144)
        XCTAssertTrue(PhantomBridge.computeVpnRoutes(directCidrs: text).isEmpty)
    }
}
