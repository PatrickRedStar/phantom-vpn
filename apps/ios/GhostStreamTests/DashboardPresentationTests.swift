import XCTest
import PhantomKit
@testable import GhostStream

final class DashboardPresentationTests: XCTestCase {
    func testDisconnectedPresentationUsesStandbyCopyAndConnectAction() {
        let result = DashboardPresentation.make(
            state: .disconnected,
            activeProfileName: nil,
            timerText: "--:--:--",
            routeIsDirect: true,
            subscriptionText: nil
        )

        XCTAssertEqual(result.title, "Standby")
        XCTAssertEqual(result.subtitle, "Add a profile to start VPN")
        XCTAssertEqual(result.primaryActionTitle, "Connect")
        XCTAssertEqual(result.tone, .neutral)
        XCTAssertEqual(result.routeText, "Direct")
    }

    func testConnectedPresentationUsesProfileTimerAndDisconnectAction() {
        let result = DashboardPresentation.make(
            state: .connected(since: Date(timeIntervalSince1970: 100), serverName: "stockholm-admin"),
            activeProfileName: "stockholm-admin",
            timerText: "00:07:42",
            routeIsDirect: false,
            subscriptionText: "5 days remaining"
        )

        XCTAssertEqual(result.title, "Protected")
        XCTAssertEqual(result.subtitle, "stockholm-admin · 00:07:42")
        XCTAssertEqual(result.primaryActionTitle, "Disconnect")
        XCTAssertEqual(result.tone, .success)
        XCTAssertEqual(result.routeText, "Relay")
        XCTAssertEqual(result.subscriptionText, "5 days remaining")
    }
}
