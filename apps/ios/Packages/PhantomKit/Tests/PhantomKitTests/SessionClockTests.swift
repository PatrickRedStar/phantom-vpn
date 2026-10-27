import XCTest
@testable import PhantomKit

final class SessionClockTests: XCTestCase {
    private func frame(_ state: ConnState, sessionSecs: UInt64 = 0) -> StatusFrame {
        var frame = StatusFrame.disconnected
        frame.state = state
        frame.sessionSecs = sessionSecs
        return frame
    }

    func testStartIsFixedOnFirstConnectedAndSurvivesReconnects() {
        var clock = SessionClock()
        let t0 = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(clock.stamp(frame(.connecting), now: t0).sessionStartedAt)
        XCTAssertEqual(clock.stamp(frame(.connected), now: t0).sessionStartedAt, 1_000)
        // Core reconnect: session_secs restarts, the start must not move.
        XCTAssertEqual(clock.stamp(frame(.reconnecting), now: t0 + 600).sessionStartedAt, 1_000)
        XCTAssertEqual(clock.stamp(frame(.connected, sessionSecs: 2), now: t0 + 700).sessionStartedAt, 1_000)
    }

    func testResetStartsANewSession() {
        var clock = SessionClock()
        _ = clock.stamp(frame(.connected), now: Date(timeIntervalSince1970: 1_000))

        clock.reset()

        XCTAssertNil(clock.stamp(frame(.reconnecting), now: Date(timeIntervalSince1970: 2_000)).sessionStartedAt)
        XCTAssertEqual(
            clock.stamp(frame(.connected), now: Date(timeIntervalSince1970: 3_000)).sessionStartedAt,
            3_000
        )
    }

    func testFieldRoundTripsAndIsOptionalOnTheWire() throws {
        var stamped = StatusFrame.disconnected
        stamped.sessionStartedAt = 1_234.5
        let decoded = try JSONDecoder().decode(StatusFrame.self, from: JSONEncoder().encode(stamped))
        XCTAssertEqual(decoded.sessionStartedAt, 1_234.5)

        // Core frames never carry it.
        var core = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StatusFrame.disconnected)) as! [String: Any]
        core.removeValue(forKey: "session_started_at")
        let fromCore = try JSONDecoder().decode(StatusFrame.self, from: JSONSerialization.data(withJSONObject: core))
        XCTAssertNil(fromCore.sessionStartedAt)
    }
}
