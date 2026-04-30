import XCTest
@testable import PhantomKit

final class RoutingRulesManagerTests: XCTestCase {
    func testGeoipCidrsNormalizeForRouteComputation() {
        let text = """
        # comment
        8.8.8.0/24
        2.16.20.0/23
        2001:db8::/32
        nope
        """

        XCTAssertEqual(
            RoutingRulesManager.normalizeIPv4Cidrs(from: text),
            ["8.8.0.0/18", "2.16.0.0/18"]
        )
    }

    func testCustomHostnamesAcceptV2FlyDomainPrefixes() {
        let text = """
        domain:Apple.com
        full:cdn.example.net
        https://www.ghoststream.example/path
        geosite:cn
        keyword:test
        """

        XCTAssertEqual(
            PreferencesStore.normalizedHostnames(from: text),
            ["apple.com", "cdn.example.net", "www.ghoststream.example"]
        )
    }
}
