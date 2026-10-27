import XCTest
@testable import PhantomKit

final class StatusFrameDecodingTests: XCTestCase {
    private let base = #""state":"connected","session_secs":5,"bytes_rx":0,"bytes_tx":0,"rate_rx_bps":0,"rate_tx_bps":0,"n_streams":4,"streams_up":4,"stream_activity":[]"#

    func testDecodesObservedDns() throws {
        let json = Data("{\(base),\"dns_observed\":\"1.1.1.1:853\",\"dns_queries\":12}".utf8)
        let frame = try JSONDecoder().decode(StatusFrame.self, from: json)
        XCTAssertEqual(frame.dnsObserved, "1.1.1.1:853")
        XCTAssertEqual(frame.dnsQueries, 12)
    }

    func testOlderFramesWithoutDnsStillDecode() throws {
        let frame = try JSONDecoder().decode(StatusFrame.self, from: Data("{\(base)}".utf8))
        XCTAssertNil(frame.dnsObserved)
        XCTAssertEqual(frame.dnsQueries, 0)
    }
}
