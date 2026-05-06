import XCTest
@testable import PhantomKit

final class VpnStateNotificationPolicyTests: XCTestCase {
    func testInitialFrameDoesNotNotify() {
        let notification = VpnStateNotificationPolicy.notification(
            previous: nil,
            current: frame(.connected),
            enabled: true
        )

        XCTAssertNil(notification)
    }

    func testDisabledPreferenceSuppressesNotifications() {
        let notification = VpnStateNotificationPolicy.notification(
            previous: frame(.connecting),
            current: frame(.connected),
            enabled: false
        )

        XCTAssertNil(notification)
    }

    func testConnectedTransitionNotifies() throws {
        let notification = try XCTUnwrap(VpnStateNotificationPolicy.notification(
            previous: frame(.connecting),
            current: frame(.connected, serverName: "work-edge"),
            enabled: true
        ))

        XCTAssertEqual(notification.title, "GhostStream connected")
        XCTAssertEqual(notification.body, "work-edge")
    }

    func testReconnectingTransitionNotifiesWithAttempt() throws {
        let notification = try XCTUnwrap(VpnStateNotificationPolicy.notification(
            previous: frame(.connected),
            current: frame(.reconnecting, reconnectAttempt: 2, reconnectNextDelaySecs: 4),
            enabled: true
        ))

        XCTAssertEqual(notification.title, "GhostStream reconnecting")
        XCTAssertTrue(notification.body.contains("attempt 2"))
        XCTAssertTrue(notification.body.contains("4s"))
    }

    func testDisconnectedTransitionNotifies() throws {
        let notification = try XCTUnwrap(VpnStateNotificationPolicy.notification(
            previous: frame(.connected),
            current: frame(.disconnected),
            enabled: true
        ))

        XCTAssertEqual(notification.title, "GhostStream disconnected")
    }

    private func frame(
        _ state: ConnState,
        serverName: String? = nil,
        lastError: String? = nil,
        reconnectAttempt: UInt32? = nil,
        reconnectNextDelaySecs: UInt32? = nil
    ) -> StatusFrame {
        StatusFrame(
            state: state,
            sessionSecs: 10,
            bytesRx: 0,
            bytesTx: 0,
            rateRxBps: 0,
            rateTxBps: 0,
            nStreams: 0,
            streamsUp: 0,
            streamActivity: Array(repeating: 0, count: 16),
            rttMs: nil,
            tunAddr: nil,
            serverAddr: nil,
            sni: serverName,
            lastError: lastError,
            reconnectAttempt: reconnectAttempt,
            reconnectNextDelaySecs: reconnectNextDelaySecs
        )
    }
}
