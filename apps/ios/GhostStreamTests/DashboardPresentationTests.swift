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

        XCTAssertEqual(result.title, L("native.dashboard.standby", "Standby"))
        XCTAssertEqual(result.subtitle, L("native.dashboard.add.profile", "Add a profile to start VPN"))
        XCTAssertEqual(result.primaryActionTitle, L("action_connect", "Connect"))
        XCTAssertEqual(result.tone, .neutral)
        XCTAssertEqual(result.routeText, L("native.dashboard.direct", "Direct"))
    }

    func testConnectedPresentationUsesProfileTimerAndDisconnectAction() {
        let result = DashboardPresentation.make(
            state: .connected(since: Date(timeIntervalSince1970: 100), serverName: "stockholm-admin"),
            activeProfileName: "stockholm-admin",
            timerText: "00:07:42",
            routeIsDirect: false,
            subscriptionText: "5 days remaining"
        )

        XCTAssertEqual(result.title, L("native.dashboard.protected", "Protected"))
        XCTAssertEqual(result.subtitle, "stockholm-admin · 00:07:42")
        XCTAssertEqual(result.primaryActionTitle, L("action_disconnect", "Disconnect"))
        XCTAssertEqual(result.tone, .success)
        XCTAssertEqual(result.routeText, L("native.dashboard.relay", "Relay"))
        XCTAssertEqual(result.subscriptionText, "5 days remaining")
    }

    private func L(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }
}
