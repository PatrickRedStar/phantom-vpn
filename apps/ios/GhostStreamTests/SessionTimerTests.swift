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

    func testReadsSessionStartedAtFromJSON() {
        let json = Data(#"{"kind":"connected","since":1,"session_started_at":1799990000.5}"#.utf8)
        XCTAssertEqual(VpnStateManager.sessionStartedAt(in: json), 1_799_990_000.5)
        XCTAssertNil(VpnStateManager.sessionStartedAt(in: Data(#"{"kind":"connected"}"#.utf8)))
    }
}
