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
            ["8.8.0.0/13", "2.16.0.0/13"]
        )
    }

    func testGeoipRulesPreserveIPv4AndIPv6Separately() {
        let text = """
        # comment
        5.255.255.0/24
        77.88.44.0/24
        2A02:6B8::/45
        nope
        """

        let rules = RoutingRulesManager.normalizeGeoipCidrs(from: text)

        XCTAssertEqual(rules.ipv4Cidrs, ["5.248.0.0/13", "77.88.0.0/13"])
        XCTAssertEqual(rules.ipv6Cidrs, ["2a02:6b8::/45"])
    }

    func testMergedCountryRulesReturnsIPv4AndIPv6() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let manager = RoutingRulesManager(baseDirectory: folder)
        let preset = RoutingRulePreset(source: .geoip, code: "ru", labelKey: "")
        let file = manager.fileURL(for: preset)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        # ghoststream-format: geoip-v2-mixed
        5.255.192.0/18
        77.88.0.0/18
        2a02:6b8::/45
        """.write(to: file, atomically: true, encoding: .utf8)

        let rules = manager.mergedCountryRules(countryCodes: ["ru", "ru"])

        XCTAssertEqual(rules.ipv4Cidrs, ["5.248.0.0/13", "77.88.0.0/13"])
        XCTAssertEqual(rules.ipv6Cidrs, ["2a02:6b8::/45"])
        XCTAssertEqual(rules.missingCountryCodes, [])
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
