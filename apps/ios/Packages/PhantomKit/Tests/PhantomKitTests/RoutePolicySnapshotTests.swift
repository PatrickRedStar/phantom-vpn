import XCTest
@testable import PhantomKit

final class RoutePolicySnapshotTests: XCTestCase {
    func testLayeredPolicyCombinesDirectCidrsInStableOrder() {
        let snapshot = RoutePolicySnapshot(
            mode: .layeredAuto,
            detectedUpstreamCidrs: ["10.0.0.0/8", "203.0.113.10/32"],
            manualDirectCidrs: ["8.8.8.0/24", "10.0.0.0/8"],
            manualDirectIpv6Cidrs: ["2a02:6b8::/45", "2a02:6b8::/45"],
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
        XCTAssertEqual(snapshot.directIpv6CidrsForRouteComputation, ["2a02:6b8::/45"])
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

    func testIPv6CidrValidationSeparatesValidAndInvalidEntries() {
        let result = RoutePolicySnapshot.normalizedIPv6Cidrs(from: """
        2a02:6b8::/45
        2A02:6B8::/45
        2001:db8::1/128
        10.0.0.0/8
        bad
        """ )

        XCTAssertEqual(result.valid, ["2a02:6b8::/45", "2001:db8::1/128"])
        XCTAssertEqual(result.invalid, ["10.0.0.0/8", "bad"])
    }

    func testRouteHashIncludesIPv6DirectCidrs() {
        let ipv4Only = RoutePolicySnapshot(
            mode: .publicSplit,
            manualDirectCidrs: ["77.88.0.0/18"],
            generatedAtUnixMs: 42
        )
        let withIPv6 = RoutePolicySnapshot(
            mode: .publicSplit,
            manualDirectCidrs: ["77.88.0.0/18"],
            manualDirectIpv6Cidrs: ["2a02:6b8::/45"],
            generatedAtUnixMs: 42
        )

        XCTAssertNotEqual(ipv4Only.routeHash, withIPv6.routeHash)
    }

    func testRouteableIPv6CidrsRejectsCountrySizedLists() {
        let cidrs = (0...RoutePolicySnapshot.maxDirectIPv6RouteCount).map {
            "2001:db8:\(String($0, radix: 16))::/48"
        }

        XCTAssertEqual(RoutePolicySnapshot.routeableIPv6Cidrs(cidrs), [])
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
        XCTAssertEqual(snapshot.manualDirectIpv6Cidrs, [])
    }
}

// MARK: - aggregatedUpstreamCidrs (Cisco dynamic split-include, июль 2026)

final class AggregatedUpstreamCidrsTests: XCTestCase {
    func testHostRoutesRoundToSlash24AndDedupe() {
        let result = RoutePolicySnapshot.aggregatedUpstreamCidrs([
            "3.65.102.105/32",
            "3.65.102.200/32",
            "3.65.103.7/32",
        ])
        XCTAssertEqual(result, ["3.65.102.0/24", "3.65.103.0/24"])
    }

    func testWidePrefixesSurviveAndSwallowChildren() {
        let result = RoutePolicySnapshot.aggregatedUpstreamCidrs([
            "10.0.0.0/8",
            "10.5.0.0/16",
            "10.6.7.8/32",
            "172.20.0.0/16",
        ])
        XCTAssertEqual(result, ["10.0.0.0/8", "172.20.0.0/16"])
    }

    func testLadderDropsToWiderPrefixWhenOverCap() {
        // 300 хостов в разных /24 (по одному на /24) → на /24 их 300 > 192,
        // на /20 — 300 разных /20? Нет: адреса подобраны так, что /20
        // схлопывает их в 75 сетей.
        var cidrs: [String] = []
        for i in 0..<300 {
            let secondOctet = i / 16
            let thirdOctet = (i % 16)
            cidrs.append("50.\(secondOctet).\(thirdOctet).1/32")
        }
        let result = RoutePolicySnapshot.aggregatedUpstreamCidrs(cidrs)
        XCTAssertLessThanOrEqual(result.count, RoutePolicySnapshot.maxDetectedIPv4RouteCount)
        XCTAssertTrue(result.allSatisfy { $0.hasSuffix("/20") || $0.hasSuffix("/16") })
    }

    func testStableOrderGivesStableHash() {
        let a = RoutePolicySnapshot.aggregatedUpstreamCidrs(["9.9.9.9/32", "1.1.1.1/32"])
        let b = RoutePolicySnapshot.aggregatedUpstreamCidrs(["1.1.1.5/32", "9.9.9.200/32"])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, ["1.1.1.0/24", "9.9.9.0/24"])
    }

    func testNewHostInExistingSupernetDoesNotChangeSet() {
        let before = RoutePolicySnapshot.aggregatedUpstreamCidrs(["3.164.240.10/32"])
        let after = RoutePolicySnapshot.aggregatedUpstreamCidrs(["3.164.240.10/32", "3.164.240.99/32"])
        XCTAssertEqual(before, after)
    }

    func testEmptyAndGarbageInput() {
        XCTAssertEqual(RoutePolicySnapshot.aggregatedUpstreamCidrs([]), [])
        XCTAssertEqual(RoutePolicySnapshot.aggregatedUpstreamCidrs(["not-a-cidr", "300.1.1.1/32"]), [])
    }
}
