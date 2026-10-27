import XCTest
@testable import GhostStream

@MainActor
final class SessionTimerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testExtensionSessionStartWinsOverSessionSecs() {
        let start = VpnStateManager.sessionStart(startedAt: 1_799_990_000, sessionSecs: 5, now: now)
        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_799_990_000))
    }

    func testFallsBackToSessionSecs() {
        let start = VpnStateManager.sessionStart(startedAt: nil, sessionSecs: 90, now: now)
        XCTAssertEqual(start, now.addingTimeInterval(-90))
    }

    func testJitterKeepsSessionStartAcrossReconnecting() {
        let current = VpnState.connected(since: now, serverName: "nl")
        let next = VpnStateManager.steady(.reconnecting(since: now.addingTimeInterval(1), serverName: "nl"), current: current)
        XCTAssertEqual(next, .reconnecting(since: now, serverName: "nl"))
    }

    func testNewSessionReplacesStart() {
        let current = VpnState.connected(since: now, serverName: "nl")
        let later = now.addingTimeInterval(600)
        XCTAssertEqual(
            VpnStateManager.steady(.connected(since: later, serverName: "nl"), current: current),
            .connected(since: later, serverName: "nl")
        )
    }
}

@MainActor
final class ReconnectCountdownTests: XCTestCase {
    func testCountsDownAndDropsNumberWhenDialing() {
        let seen = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(DashboardViewModel.secondsLeft(delay: 5, since: seen, now: seen), 5)
        XCTAssertEqual(DashboardViewModel.secondsLeft(delay: 5, since: seen, now: seen.addingTimeInterval(3.2)), 2)
        XCTAssertNil(DashboardViewModel.secondsLeft(delay: 5, since: seen, now: seen.addingTimeInterval(5)))
        XCTAssertNil(DashboardViewModel.secondsLeft(delay: nil, since: seen, now: seen))
    }
}
