import XCTest
@testable import PhantomKit

/// ConnStringBuilder — единственный источник `ghs://` при пустом
/// `profile.connString` (fallback в `PhantomBridge.start`). Регрессия здесь
/// = BridgeError.encoding и мгновенный cancel туннеля (см. инцидент
/// 2026-05-17), поэтому формат закреплён тестами.
final class ConnStringBuilderTests: XCTestCase {

    private func profile(
        cert: String? = "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----",
        key: String? = "-----BEGIN PRIVATE KEY-----\nxyz\n-----END PRIVATE KEY-----"
    ) -> VpnProfile {
        VpnProfile(
            id: "test-id",
            name: "unit",
            serverAddr: "203.0.113.7:8443",
            serverName: "tls.example.com",
            certPem: cert,
            keyPem: key,
            tunAddr: "10.7.0.5/24"
        )
    }

    func testBuildProducesParsableGhsUrl() throws {
        let conn = try XCTUnwrap(ConnStringBuilder.build(from: profile()))

        XCTAssertTrue(conn.hasPrefix("ghs://"))
        XCTAssertTrue(conn.contains("@203.0.113.7:8443?"))
        XCTAssertTrue(conn.contains("sni=tls.example.com"))
        // "/" входит в .urlQueryAllowed и НЕ кодируется — Rust-парсер
        // принимает сырой CIDR (фиксируем фактический wire-формат).
        XCTAssertTrue(conn.contains("tun=10.7.0.5/24"))
        XCTAssertTrue(conn.hasSuffix("&v=1"))
    }

    func testUserinfoIsBase64UrlOfCertAndKey() throws {
        let conn = try XCTUnwrap(ConnStringBuilder.build(from: profile()))
        let afterScheme = conn.dropFirst("ghs://".count)
        let userinfo = String(afterScheme.prefix(while: { $0 != "@" }))

        // base64url без паддинга — URL-safe алфавит
        XCTAssertFalse(userinfo.contains("+"))
        XCTAssertFalse(userinfo.contains("/"))
        XCTAssertFalse(userinfo.contains("="))

        // Декодируется обратно в "cert\nkey"
        var b64 = userinfo
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        let decoded = try XCTUnwrap(
            Data(base64Encoded: b64).flatMap { String(data: $0, encoding: .utf8) }
        )
        XCTAssertTrue(decoded.hasPrefix("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(decoded.contains("-----END CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----"))
        XCTAssertTrue(decoded.hasSuffix("-----END PRIVATE KEY-----"))
    }

    func testPemWhitespaceIsTrimmedBeforeEncoding() throws {
        let padded = profile(
            cert: "\n\n-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----\n\n",
            key: "  -----BEGIN PRIVATE KEY-----\nxyz\n-----END PRIVATE KEY-----  "
        )
        let clean = profile()
        XCTAssertEqual(
            ConnStringBuilder.build(from: padded),
            ConnStringBuilder.build(from: clean)
        )
    }

    func testMissingCertOrKeyReturnsNil() {
        XCTAssertNil(ConnStringBuilder.build(from: profile(cert: nil)))
        XCTAssertNil(ConnStringBuilder.build(from: profile(key: nil)))
        XCTAssertNil(ConnStringBuilder.build(from: profile(cert: "")))
        XCTAssertNil(ConnStringBuilder.build(from: profile(key: "")))
    }
}
