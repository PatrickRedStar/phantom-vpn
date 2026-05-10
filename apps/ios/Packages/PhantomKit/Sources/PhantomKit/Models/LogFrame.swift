import Foundation

/// Codable mirror of the Rust `LogFrame` delivered via the log callback
/// from `phantom_runtime_start`.
///
/// v2 (per ADR 0008) extends the v1 wire format with:
///  - `tsUnixUs` — microsecond timestamp; defaults to 0 from the Rust side
///    when missing, in which case consumers fall back to `tsUnixMs * 1000`.
///  - `category` — logical category ("tunnel" / "handshake" / "stream" /
///    "packet" / "telemetry" / "tun" / "ipc" / "settings" / "runtime" /
///    "ffi"). `nil` for v1 frames.
///  - `fields` — small map of stringified key/value attributes. `nil` when
///    the producer emitted no structured context.
///
/// All v2 fields decode through `decodeIfPresent`, so a payload from an
/// older Rust runtime (no `ts_unix_us`, no `category`, no `fields`) still
/// round-trips through `JSONDecoder` without errors.
public struct LogFrame: Codable, Equatable, Identifiable {

    /// Legacy millisecond timestamp. Always present on the wire.
    public var tsUnixMs: UInt64

    /// Microsecond timestamp. v2 only — `0` when the producer is v1.
    /// Use `timestampUs` to read the effective microsecond timestamp.
    public var tsUnixUs: UInt64

    /// 3-char level code ("ERR" / "WRN" / "INF" / "DBG" / "TRC"). The
    /// legacy "OK" alias is preserved for backward compat — UI normalises
    /// to "info".
    public var level: String

    /// Free-form human-readable message.
    public var msg: String

    /// Optional logical category. v2 only.
    public var category: String?

    /// Optional structured key/value attributes. v2 only.
    public var fields: [String: String]?

    public var id: String {
        "\(tsUnixUs == 0 ? tsUnixMs &* 1_000 : tsUnixUs)|\(level)|\(category ?? "")|\(msg)"
    }

    /// Effective microsecond timestamp. Falls back to `tsUnixMs * 1000`
    /// when `tsUnixUs == 0` (v1 wire format or unknown microseconds).
    public var timestampUs: UInt64 {
        tsUnixUs != 0 ? tsUnixUs : tsUnixMs &* 1_000
    }

    enum CodingKeys: String, CodingKey {
        case tsUnixMs = "ts_unix_ms"
        case tsUnixUs = "ts_unix_us"
        case level
        case msg
        case category
        case fields
    }

    public init(
        tsUnixMs: UInt64,
        tsUnixUs: UInt64 = 0,
        level: String,
        msg: String,
        category: String? = nil,
        fields: [String: String]? = nil
    ) {
        self.tsUnixMs = tsUnixMs
        self.tsUnixUs = tsUnixUs
        self.level = level
        self.msg = msg
        self.category = category
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tsUnixMs = try c.decode(UInt64.self, forKey: .tsUnixMs)
        self.tsUnixUs = try c.decodeIfPresent(UInt64.self, forKey: .tsUnixUs) ?? 0
        self.level = try c.decode(String.self, forKey: .level)
        self.msg = try c.decode(String.self, forKey: .msg)
        self.category = try c.decodeIfPresent(String.self, forKey: .category)
        self.fields = try c.decodeIfPresent([String: String].self, forKey: .fields)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tsUnixMs, forKey: .tsUnixMs)
        if tsUnixUs != 0 {
            try c.encode(tsUnixUs, forKey: .tsUnixUs)
        }
        try c.encode(level, forKey: .level)
        try c.encode(msg, forKey: .msg)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(fields, forKey: .fields)
    }

    /// v2 helper: build a structured Swift-side frame with category and
    /// optional fields. Fills both `tsUnixMs` and `tsUnixUs` from the
    /// current wall-clock time.
    public static func structured(
        level: String,
        category: String,
        msg: String,
        fields: [String: String]? = nil
    ) -> LogFrame {
        let now = Date().timeIntervalSince1970
        let ms = UInt64((now * 1_000).rounded())
        let us = UInt64((now * 1_000_000).rounded())
        let normalized = (fields?.isEmpty ?? true) ? nil : fields
        return LogFrame(
            tsUnixMs: ms,
            tsUnixUs: us,
            level: level,
            msg: msg,
            category: category,
            fields: normalized
        )
    }
}
