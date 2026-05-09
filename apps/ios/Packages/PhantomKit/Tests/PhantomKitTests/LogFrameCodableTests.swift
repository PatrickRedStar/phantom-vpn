import XCTest
@testable import PhantomKit

/// Backward/forward compat tests for the v2 `LogFrame` codable schema
/// added by ADR 0008. The wire format is shared with Rust `gui-ipc`,
/// so any drift between Rust serialization and Swift parsing surfaces
/// here.
final class LogFrameCodableTests: XCTestCase {

    private func decode(_ json: String) throws -> LogFrame {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(LogFrame.self, from: data)
    }

    private func encode(_ frame: LogFrame) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(frame)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - v1 compatibility

    /// A v1 payload (no `ts_unix_us`, no `category`, no `fields`) must
    /// decode without errors and surface a `timestampUs` derived from
    /// `ts_unix_ms`.
    func test_v1Payload_decodesAndDerivesMicroseconds() throws {
        let v1 = #"{"ts_unix_ms":1700000000000,"level":"INF","msg":"hello"}"#
        let frame = try decode(v1)
        XCTAssertEqual(frame.tsUnixMs, 1_700_000_000_000)
        XCTAssertEqual(frame.tsUnixUs, 0)
        XCTAssertEqual(frame.level, "INF")
        XCTAssertEqual(frame.msg, "hello")
        XCTAssertNil(frame.category)
        XCTAssertNil(frame.fields)
        // Derived timestamp falls back to ms*1000 for v1 frames.
        XCTAssertEqual(frame.timestampUs, 1_700_000_000_000_000)
    }

    /// Encoding a v1 frame (zero microseconds, no category/fields)
    /// MUST omit the v2 keys so old consumers that strict-decode
    /// continue to parse the payload.
    func test_v1Frame_encodesWithoutV2Keys() throws {
        let frame = LogFrame(
            tsUnixMs: 1_700_000_000_000,
            level: "INF",
            msg: "hello"
        )
        let json = try encode(frame)
        XCTAssertFalse(json.contains("ts_unix_us"), "v1 frame must not emit ts_unix_us")
        XCTAssertFalse(json.contains("category"), "v1 frame must not emit category")
        XCTAssertFalse(json.contains("fields"), "v1 frame must not emit fields")
        XCTAssertTrue(json.contains("\"ts_unix_ms\":1700000000000"))
    }

    // MARK: - v2 round-trip

    func test_v2Payload_roundTripsExactly() throws {
        let v2 = """
        {"ts_unix_ms":1700000000000,\
        "ts_unix_us":1700000000000123,\
        "level":"DBG",\
        "msg":"handshake.tls.client_hello",\
        "category":"handshake",\
        "fields":{"alpn":"h2","sni":"example.com"}}
        """
        let frame = try decode(v2)
        XCTAssertEqual(frame.tsUnixUs, 1_700_000_000_000_123)
        XCTAssertEqual(frame.timestampUs, 1_700_000_000_000_123)
        XCTAssertEqual(frame.category, "handshake")
        XCTAssertEqual(frame.fields?["alpn"], "h2")
        XCTAssertEqual(frame.fields?["sni"], "example.com")

        let reEncoded = try encode(frame)
        let reDecoded = try decode(reEncoded)
        XCTAssertEqual(reDecoded, frame, "v2 round-trip must preserve every field")
    }

    /// `LogFrame.structured` is the canonical v2 builder used by Provider
    /// state events. It must always populate microseconds and category,
    /// and collapse empty `fields` to `nil`.
    func test_structuredHelper_populatesV2Fields() {
        let frame = LogFrame.structured(
            level: "INF",
            category: "tunnel",
            msg: "started",
            fields: nil
        )
        XCTAssertGreaterThan(frame.tsUnixUs, 0)
        XCTAssertGreaterThan(frame.tsUnixMs, 0)
        XCTAssertEqual(frame.category, "tunnel")
        XCTAssertNil(frame.fields)
    }

    func test_structuredHelper_emptyFieldsBecomeNil() {
        let frame = LogFrame.structured(
            level: "INF",
            category: "tunnel",
            msg: "started",
            fields: [:]
        )
        XCTAssertNil(frame.fields, "empty fields must collapse to nil for parity with Rust")
    }

    /// `id` must vary across timestamp / level / msg / category
    /// so SwiftUI's `ForEach(_, id:)` doesn't merge unrelated rows.
    func test_id_includesCategoryAndMicroseconds() {
        let a = LogFrame(
            tsUnixMs: 1,
            tsUnixUs: 1_000_001,
            level: "INF",
            msg: "x",
            category: "tunnel"
        )
        let b = LogFrame(
            tsUnixMs: 1,
            tsUnixUs: 1_000_002,
            level: "INF",
            msg: "x",
            category: "tunnel"
        )
        let c = LogFrame(
            tsUnixMs: 1,
            tsUnixUs: 1_000_001,
            level: "INF",
            msg: "x",
            category: "stream"
        )
        XCTAssertNotEqual(a.id, b.id, "different microseconds must produce distinct ids")
        XCTAssertNotEqual(a.id, c.id, "different categories must produce distinct ids")
    }
}
