import XCTest
@testable import PhantomKit

final class TunnelSettingsTests: XCTestCase {
    func testStreamsDefaultToAutomatic() throws {
        let settings = TunnelSettings()

        XCTAssertNil(settings.streams)
    }

    func testManualStreamsAreEncoded() throws {
        let settings = TunnelSettings(streams: 12)
        let data = try JSONEncoder().encode(settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["streams"] as? Int, 12)
    }

    func testManualStreamsAreClampedToSupportedRange() {
        XCTAssertEqual(TunnelSettings(streams: 1).streams, 2)
        XCTAssertEqual(TunnelSettings(streams: 99).streams, 16)
    }
}
