import XCTest
@testable import PhantomKit

final class TelemetryDisplayHelpersTests: XCTestCase {

    // MARK: - barCountFromStreams

    func testBarCountClampsZeroToOne() {
        XCTAssertEqual(TelemetryDisplayHelpers.barCountFromStreams(0), 1)
    }

    func testBarCountPassesValidRangeThrough() {
        XCTAssertEqual(TelemetryDisplayHelpers.barCountFromStreams(1), 1)
        XCTAssertEqual(TelemetryDisplayHelpers.barCountFromStreams(8), 8)
        XCTAssertEqual(TelemetryDisplayHelpers.barCountFromStreams(10), 10)
        XCTAssertEqual(TelemetryDisplayHelpers.barCountFromStreams(16), 16)
    }

    func testBarCountClampsAboveSixteen() {
        XCTAssertEqual(TelemetryDisplayHelpers.barCountFromStreams(17), 16)
        XCTAssertEqual(TelemetryDisplayHelpers.barCountFromStreams(255), 16)
    }

    // MARK: - bytesPerSecondFromBitsPerSecond

    func testBitsToBytesBasic() {
        XCTAssertEqual(
            TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(16384),
            2048,
            accuracy: 0.0001
        )
    }

    func testBitsToBytesZero() {
        XCTAssertEqual(TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(0), 0)
    }

    func testBitsToBytesNonFiniteIsZero() {
        XCTAssertEqual(
            TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(.infinity),
            0
        )
        XCTAssertEqual(
            TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(.nan),
            0
        )
    }

    func testBitsToBytesNegativeIsZero() {
        XCTAssertEqual(
            TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(-1024),
            0
        )
    }

    /// Reproduces the kvGrid `RX · RATE` flow:
    ///   runtime emits `rate_rx_bps` in bits/sec → bytes/sec → KB/s string.
    /// 16384 bits/sec = 2048 bytes/sec = 2 KB/s.
    func testFullKvCellPipelineFor16384Bps() {
        let bytesPerSecond = TelemetryDisplayHelpers
            .bytesPerSecondFromBitsPerSecond(16384)
        let kb = bytesPerSecond / 1024.0
        XCTAssertEqual(String(format: "%.0f", kb), "2")
        XCTAssertLessThan(kb, 1024)  // stays in KB/s bucket
    }
}
