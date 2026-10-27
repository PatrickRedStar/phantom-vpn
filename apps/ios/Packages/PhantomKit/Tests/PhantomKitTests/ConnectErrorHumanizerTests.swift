import XCTest
@testable import PhantomKit

final class ConnectErrorHumanizerTests: XCTestCase {

    func testCredentialsMissing() {
        let out = ConnectErrorHumanizer.humanize(
            "VPN credentials missing — re-import the ghs:// URL in Settings → Profiles"
        )
        XCTAssertTrue(out.contains("переимпортируйте"))
    }

    func testHandshakeTimeout() {
        XCTAssertTrue(ConnectErrorHumanizer.humanize("VPN handshake timed out").contains("таймаут"))
    }

    func testExtensionNotApproved() {
        let out = ConnectErrorHumanizer.humanize("The system extension is awaiting user approval")
        XCTAssertTrue(out.contains("Системных настройках"))
    }

    func testNoNetwork() {
        XCTAssertTrue(ConnectErrorHumanizer.humanize("Network is down").contains("Нет сети"))
    }

    func testConnectionRefused() {
        XCTAssertTrue(ConnectErrorHumanizer.humanize("Connection refused").contains("недоступен"))
    }

    func testMtls() {
        XCTAssertTrue(
            ConnectErrorHumanizer.humanize("bad certificate: mTLS handshake failure").contains("сертификат")
        )
    }

    func testSplitRoutingFailure() {
        let out = ConnectErrorHumanizer.humanize(
            "Split-routing failed: route computation returned no VPN routes for 3 direct CIDRs"
        )
        XCTAssertTrue(out.contains("split-routing") || out.contains("маршрут"))
    }

    func testUnknownErrorKeepsTechnicalTail() {
        let out = ConnectErrorHumanizer.humanize("Weird Rust panic 0xdeadbeef")
        XCTAssertTrue(out.contains("Не удалось подключиться"))
        XCTAssertTrue(out.contains("Weird Rust panic 0xdeadbeef"))
    }

    func testEnglishVariant() {
        XCTAssertTrue(ConnectErrorHumanizer.humanize("Network is down", english: true).contains("No network"))
        XCTAssertTrue(
            ConnectErrorHumanizer.humanize("Weird Rust panic 0xdeadbeef", english: true)
                .hasSuffix("Weird Rust panic 0xdeadbeef")
        )
    }

    func testEmptyErrorFallsBack() {
        XCTAssertEqual(
            ConnectErrorHumanizer.humanize("   "),
            "Не удалось подключиться. Попробуйте ещё раз."
        )
    }
}
