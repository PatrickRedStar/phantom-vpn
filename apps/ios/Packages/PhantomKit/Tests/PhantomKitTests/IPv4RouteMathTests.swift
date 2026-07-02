import XCTest
@testable import PhantomKit

final class IPv4RouteMathTests: XCTestCase {

    // MARK: - prefixLength

    func testContiguousMasks() {
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 255, 255]), 32)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 255, 0]), 24)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 0, 0]), 16)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 255, 224]), 27)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 255, 248]), 29)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [0, 0, 0, 0]), 0)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [128, 0, 0, 0]), 1)
    }

    func testTruncatedMaskPaddedWithZeros() {
        // route-table отдаёт короткий sockaddr для «круглых» масок:
        // [255,255] => /16.
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255]), 16)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255]), 8)
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: []), 0)
    }

    func testNonContiguousMaskIsRejected() {
        XCTAssertNil(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 0, 255, 0]))
        XCTAssertNil(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 255, 1]))
        XCTAssertNil(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 254, 255]))
    }

    func testMaskLongerThanFourBytesTruncated() {
        XCTAssertEqual(IPv4RouteMath.prefixLength(fromMaskBytes: [255, 255, 255, 0, 99]), 24)
    }

    // MARK: - cidrSortsBefore

    func testSortByOctetsThenPrefix() {
        var cidrs = ["10.4.0.0/18", "3.65.0.0/16", "10.4.0.0/24", "3.64.0.0/16"]
        cidrs.sort(by: IPv4RouteMath.cidrSortsBefore)
        XCTAssertEqual(cidrs, ["3.64.0.0/16", "3.65.0.0/16", "10.4.0.0/18", "10.4.0.0/24"])
    }

    func testSortIsNumericNotLexicographic() {
        // "10" < "9" лексикографически, но 9 < 10 численно
        var cidrs = ["10.0.0.0/8", "9.0.0.0/8"]
        cidrs.sort(by: IPv4RouteMath.cidrSortsBefore)
        XCTAssertEqual(cidrs, ["9.0.0.0/8", "10.0.0.0/8"])
    }
}
