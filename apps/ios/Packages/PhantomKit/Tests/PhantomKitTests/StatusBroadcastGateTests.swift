import XCTest
@testable import PhantomKit

final class StatusBroadcastGateTests: XCTestCase {
    func testFirstFrameBroadcastsImmediately() {
        var gate = StatusBroadcastGate(minInterval: 1.0)

        XCTAssertTrue(gate.shouldBroadcast(frame(state: .connected), now: 10.0))
    }

    func testSteadyStateIsThrottledUntilIntervalPasses() {
        var gate = StatusBroadcastGate(minInterval: 1.0)

        XCTAssertTrue(gate.shouldBroadcast(frame(state: .connected), now: 10.0))
        XCTAssertFalse(gate.shouldBroadcast(frame(state: .connected), now: 10.25))
        XCTAssertFalse(gate.shouldBroadcast(frame(state: .connected), now: 10.99))
        XCTAssertTrue(gate.shouldBroadcast(frame(state: .connected), now: 11.0))
    }

    func testStateChangesBypassThrottle() {
        var gate = StatusBroadcastGate(minInterval: 1.0)

        XCTAssertTrue(gate.shouldBroadcast(frame(state: .connecting), now: 10.0))
        XCTAssertTrue(gate.shouldBroadcast(frame(state: .connected), now: 10.1))
    }

    func testErrorMessageChangesBypassThrottle() {
        var gate = StatusBroadcastGate(minInterval: 1.0)

        XCTAssertTrue(gate.shouldBroadcast(frame(state: .error, lastError: "first"), now: 10.0))
        XCTAssertTrue(gate.shouldBroadcast(frame(state: .error, lastError: "second"), now: 10.1))
    }

    func testReconnectDetailsBypassThrottle() {
        var gate = StatusBroadcastGate(minInterval: 1.0)

        XCTAssertTrue(gate.shouldBroadcast(
            frame(state: .reconnecting, reconnectAttempt: 1, reconnectNextDelaySecs: 2),
            now: 10.0
        ))
        XCTAssertTrue(gate.shouldBroadcast(
            frame(state: .reconnecting, reconnectAttempt: 2, reconnectNextDelaySecs: 4),
            now: 10.1
        ))
    }

    func testResetAllowsImmediateBroadcast() {
        var gate = StatusBroadcastGate(minInterval: 1.0)

        XCTAssertTrue(gate.shouldBroadcast(frame(state: .connected), now: 10.0))
        XCTAssertFalse(gate.shouldBroadcast(frame(state: .connected), now: 10.1))
        gate.reset()
        XCTAssertTrue(gate.shouldBroadcast(frame(state: .connected), now: 10.2))
    }

    private func frame(
        state: ConnState,
        lastError: String? = nil,
        reconnectAttempt: UInt32? = nil,
        reconnectNextDelaySecs: UInt32? = nil
    ) -> StatusFrame {
        StatusFrame(
            state: state,
            sessionSecs: 1,
            bytesRx: 100,
            bytesTx: 50,
            rateRxBps: 10,
            rateTxBps: 5,
            nStreams: 8,
            streamsUp: 8,
            streamActivity: Array(repeating: 0.5, count: 16),
            rttMs: nil,
            tunAddr: nil,
            serverAddr: nil,
            sni: nil,
            lastError: lastError,
            reconnectAttempt: reconnectAttempt,
            reconnectNextDelaySecs: reconnectNextDelaySecs
        )
    }
}
