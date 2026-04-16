import Foundation

/// Codable mirror of the Rust log frame delivered via the log callback
/// from `phantom_runtime_start`.
public struct LogFrame: Codable, Identifiable {
    public var tsUnixMs: UInt64
    public var level: String
    public var msg: String

    public var id: UInt64 { tsUnixMs }

    enum CodingKeys: String, CodingKey {
        case tsUnixMs = "ts_unix_ms"
        case level
        case msg
    }

    public init(tsUnixMs: UInt64, level: String, msg: String) {
        self.tsUnixMs = tsUnixMs
        self.level = level
        self.msg = msg
    }
}
