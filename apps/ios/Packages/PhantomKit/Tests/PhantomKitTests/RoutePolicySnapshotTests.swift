import XCTest
@testable import PhantomKit

final class RoutePolicySnapshotTests: XCTestCase {
    func testLayeredPolicyCombinesDirectCidrsInStableOrder() {
        let snapshot = RoutePolicySnapshot(
            mode: .layeredAuto,
            detectedUpstreamCidrs: ["10.0.0.0/8", "203.0.113.10/32"],
            manualDirectCidrs: ["8.8.8.0/24", "10.0.0.0/8"],
            serverDirectCidrs: ["198.51.100.20/32"],
            upstreamDnsServers: ["10.0.0.114"],
            upstreamDnsDomains: ["corp.example"],
            upstreamInterfaceNames: ["utun6"],
            upstreamProviderName: "Cisco Secure Client",
            routeHash: "hash",
            generatedAtUnixMs: 42
        )

        XCTAssertEqual(snapshot.directCidrsForRouteComputation, [
            "10.0.0.0/8",
            "203.0.113.10/32",
            "8.8.8.0/24",
            "198.51.100.20/32",
        ])
    }

    func testRoutingModeBackcompatWithSplitRouting() {
        XCTAssertEqual(RoutingMode.defaultValue(splitRouting: true), .publicSplit)
        XCTAssertEqual(RoutingMode.defaultValue(splitRouting: false), .global)
        XCTAssertEqual(RoutingMode.defaultValue(splitRouting: nil), .global)
    }

    func testCidrValidationSeparatesValidAndInvalidEntries() {
        let result = RoutePolicySnapshot.normalizedCidrs(from: """
        10.0.0.0/8
        bad
        192.168.1.1/32
        10.0.0.0/8
        # comment
        2001:db8::/32
        """)

        XCTAssertEqual(result.valid, ["10.0.0.0/8", "192.168.1.1/32"])
        XCTAssertEqual(result.invalid, ["bad", "2001:db8::/32"])
    }

    func testRoutePolicyDecodeDefaultsPreserveScopedDnsForOlderPayloads() throws {
        let data = """
        {
          "mode": "layeredAuto",
          "manual_direct_cidrs": ["8.8.8.0/24"],
          "route_hash": "legacy",
          "generated_at_unix_ms": 42
        }
        """.data(using: .utf8)!

        let snapshot = try JSONDecoder().decode(RoutePolicySnapshot.self, from: data)

        XCTAssertTrue(snapshot.preserveScopedDns)
        XCTAssertEqual(snapshot.manualDirectCidrs, ["8.8.8.0/24"])
    }
}
