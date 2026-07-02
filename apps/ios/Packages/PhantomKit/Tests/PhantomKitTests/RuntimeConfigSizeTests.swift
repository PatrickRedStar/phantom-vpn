import XCTest
@testable import PhantomKit

/// Инвариант против рецидива FFI-size бага (июль 2026): cfg_json,
/// уходящий в `phantom_runtime_start`, читается через
/// `cstr_to_str_bounded(..., MAX_FFI_CSTR_LEN = 16384)`. Полный
/// `TunnelSettings.routePolicy` c сырыми маршрутами Cisco (сотни CIDR,
/// ~10 КБ) раньше ехал в cfg и при большом split-include превышал лимит
/// → ERR_BAD_CONFIG → туннель не стартовал.
///
/// Рантайм читает из TunnelSettings только флаги + streams; routing —
/// на Swift-стороне. Поэтому cfg обязан оставаться маленьким независимо
/// от размера routePolicy. Тест кодирует ConnectProfile ровно так, как
/// это делает `PhantomBridge.start` (проекция без routePolicy/CIDR).
final class RuntimeConfigSizeTests: XCTestCase {

    private static let maxFfiCStrLen = 16_384

    /// Гигантский routePolicy — как у Cisco full split-include.
    private func hugeSettings() -> TunnelSettings {
        let manyCidrs = (0..<800).map { "10.\($0 / 256).\($0 % 256).0/24" }
        let policy = RoutePolicySnapshot(
            mode: .layeredAuto,
            detectedUpstreamCidrs: manyCidrs,
            serverDirectCidrs: ["82.38.66.138/32"],
            upstreamInterfaceNames: ["utun5"]
        )
        return TunnelSettings(
            dnsLeakProtection: true,
            ipv6Killswitch: true,
            autoReconnect: true,
            routingMode: .layeredAuto,
            manualDirectCidrs: manyCidrs,
            preserveScopedDns: true,
            routePolicy: policy,
            streams: nil
        )
    }

    /// Зеркало проекции из PhantomBridge.start — держим синхронно.
    private func runtimeProjection(_ s: TunnelSettings) -> TunnelSettings {
        TunnelSettings(
            dnsLeakProtection: s.dnsLeakProtection,
            ipv6Killswitch: s.ipv6Killswitch,
            autoReconnect: s.autoReconnect,
            routingMode: s.routingMode,
            manualDirectCidrs: [],
            manualDirectIpv6Cidrs: [],
            preserveScopedDns: s.preserveScopedDns,
            routePolicy: nil,
            streams: s.streams
        )
    }

    func testFullSettingsWouldExceedFfiLimit() throws {
        // Санити: именно поэтому нельзя слать полный settings — он огромен.
        let conn = "ghs://" + String(repeating: "A", count: 1200)
            + "@82.38.66.138:8443?sni=poland.example.com&tun=10.7.0.5/24&v=1"
        let full = ConnectProfile(name: "macbook", connString: conn, settings: hugeSettings())
        let bytes = try JSONEncoder().encode(full).count
        XCTAssertGreaterThan(bytes, Self.maxFfiCStrLen,
                             "тест-фикстура должна моделировать переполнение (\(bytes) б)")
    }

    func testRuntimeProjectionStaysUnderFfiLimit() throws {
        let conn = "ghs://" + String(repeating: "A", count: 1200)
            + "@82.38.66.138:8443?sni=poland.example.com&tun=10.7.0.5/24&v=1"
        let slim = ConnectProfile(
            name: "macbook", connString: conn,
            settings: runtimeProjection(hugeSettings())
        )
        let bytes = try JSONEncoder().encode(slim).count
        XCTAssertLessThan(bytes, Self.maxFfiCStrLen,
                          "cfg для рантайма должен укладываться в 16 КБ (\(bytes) б)")
    }

    func testRuntimeProjectionDropsRoutingBulk() throws {
        let slim = runtimeProjection(hugeSettings())
        XCTAssertNil(slim.routePolicy)
        XCTAssertTrue(slim.manualDirectCidrs.isEmpty)
        // Флаги, которые рантайм реально читает, сохранены.
        XCTAssertTrue(slim.ipv6Killswitch)
        XCTAssertEqual(slim.routingMode, .layeredAuto)
    }
}
