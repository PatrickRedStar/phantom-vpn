// NOTE: This file must stay identical to
// apps/ios/GhostStream/Rust/PhantomBridge.swift until we extract a shared
// framework. Keep the two files byte-for-byte in sync — any divergence is
// a bug.

import Foundation

// MARK: - Raw C declarations (no bridging header)

@_silgen_name("phantom_start")
private func c_phantom_start(_ cfg: UnsafePointer<CChar>?) -> Int32

@_silgen_name("phantom_stop")
private func c_phantom_stop()

@_silgen_name("phantom_submit_outbound")
private func c_phantom_submit_outbound(_ ptr: UnsafePointer<UInt8>?, _ len: Int) -> Int32

@_silgen_name("phantom_set_inbound_callback")
private func c_phantom_set_inbound_callback(
    _ cb: (@convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void)?,
    _ ctx: UnsafeMutableRawPointer?
)

@_silgen_name("phantom_get_stats")
private func c_phantom_get_stats() -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_get_logs")
private func c_phantom_get_logs(_ sinceSeq: Int64) -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_set_log_level")
private func c_phantom_set_log_level(_ level: UnsafePointer<CChar>?)

@_silgen_name("phantom_parse_conn_string")
private func c_phantom_parse_conn_string(_ input: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_compute_vpn_routes")
private func c_phantom_compute_vpn_routes(_ direct: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_free_string")
private func c_phantom_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

// MARK: - Typed Swift surface

/// JSON payload passed to `phantom_start`. Matches the Rust-side
/// `StartConfig` struct — keys are snake_case.
public struct StartConfig: Encodable {
    public var serverAddr: String
    public var serverName: String
    public var insecure: Bool
    public var certPem: String
    public var keyPem: String
    public var tunAddr: String
    public var tunMtu: Int

    private enum CodingKeys: String, CodingKey {
        case serverAddr = "server_addr"
        case serverName = "server_name"
        case insecure
        case certPem = "cert_pem"
        case keyPem = "key_pem"
        case tunAddr = "tun_addr"
        case tunMtu = "tun_mtu"
    }

    public init(
        serverAddr: String,
        serverName: String,
        insecure: Bool,
        certPem: String,
        keyPem: String,
        tunAddr: String,
        tunMtu: Int = 1350
    ) {
        self.serverAddr = serverAddr
        self.serverName = serverName
        self.insecure = insecure
        self.certPem = certPem
        self.keyPem = keyPem
        self.tunAddr = tunAddr
        self.tunMtu = tunMtu
    }
}

/// Stats snapshot returned by `phantom_get_stats` (decoded from JSON).
public struct Stats: Codable {
    public let bytesRx: Int64
    public let bytesTx: Int64
    public let pktsRx: Int64
    public let pktsTx: Int64
    public let connected: Bool

    private enum CodingKeys: String, CodingKey {
        case bytesRx = "bytes_rx"
        case bytesTx = "bytes_tx"
        case pktsRx = "pkts_rx"
        case pktsTx = "pkts_tx"
        case connected
    }
}

/// Single log entry from the Rust ring buffer.
public struct LogEntry: Codable, Identifiable {
    public let seq: Int64
    public let ts: Double
    public let level: String
    public let target: String
    public let message: String

    public var id: Int64 { seq }
}

/// Conn-string parser output. Fields match `parse_conn_string` in
/// `crates/client-common/src/helpers.rs`.
public struct ParsedConnConfig: Codable {
    public let serverAddr: String
    public let serverName: String
    public let tunAddr: String
    public let certPem: String
    public let keyPem: String

    private enum CodingKeys: String, CodingKey {
        case serverAddr = "server_addr"
        case serverName = "server_name"
        case tunAddr = "tun_addr"
        case certPem = "cert_pem"
        case keyPem = "key_pem"
    }
}

/// A single split-routing route (CIDR → in/out of tunnel).
public struct IPRoute: Codable {
    public let cidr: String
    public let viaTun: Bool

    private enum CodingKeys: String, CodingKey {
        case cidr
        case viaTun = "via_tun"
    }
}

/// Errors raised by the Swift wrapper — distinct from Rust-side error codes.
public enum PhantomError: Error {
    case startFailed(Int32)
    case encoding
    case nullReturn
}

/// Namespace-only class exposing the Rust shim as strongly-typed Swift APIs.
///
/// All string-returning C calls free their C string via `phantom_free_string`
/// inside a `defer`. The inbound packet callback is kept alive by a strong
/// static reference on `CallbackBox`.
public final class PhantomBridge {

    private final class CallbackBox {
        let cb: (Data) -> Void
        init(_ cb: @escaping (Data) -> Void) { self.cb = cb }
    }

    /// Retain root for the registered inbound callback. Replaced on every
    /// `setInboundCallback` call so stale boxes can be released.
    private static var currentBox: CallbackBox?

    /// Starts the Rust tunnel with `config`. Returns the Rust-side status
    /// code (0 on success).
    /// - Throws: `PhantomError.encoding` if JSON serialisation fails,
    ///   `PhantomError.startFailed` if the Rust side returns non-zero.
    @discardableResult
    public static func start(_ config: StartConfig) throws -> Int32 {
        let encoder = JSONEncoder()
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw PhantomError.encoding
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw PhantomError.encoding
        }
        let rc = json.withCString { c_phantom_start($0) }
        if rc != 0 { throw PhantomError.startFailed(rc) }
        return rc
    }

    /// Stops the Rust tunnel and drains background tasks. Safe to call
    /// when already stopped.
    public static func stop() {
        c_phantom_stop()
    }

    /// Submits an outbound IP packet to Rust. Drops silently when the
    /// underlying queue is full (TCP retransmissions handle loss); no-op
    /// on empty input.
    public static func submitOutbound(_ packet: Data) {
        guard !packet.isEmpty else { return }
        packet.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) in
            guard let base = rawBuf.baseAddress else { return }
            let typed = base.assumingMemoryBound(to: UInt8.self)
            _ = c_phantom_submit_outbound(typed, packet.count)
        }
    }

    /// Trampoline invoked from Rust for each inbound packet. Copies bytes
    /// into a Swift `Data` and forwards to the stored closure.
    private static let inboundTrampoline: @convention(c) (
        UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?
    ) -> Void = { ptr, len, ctx in
        guard let ptr, let ctx, len > 0 else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        box.cb(data)
    }

    /// Registers a callback invoked for each inbound packet from Rust.
    /// Only one callback may be active at a time — registering a new one
    /// replaces and releases the previous.
    public static func setInboundCallback(_ cb: @escaping (Data) -> Void) {
        let box = CallbackBox(cb)
        currentBox = box
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        c_phantom_set_inbound_callback(inboundTrampoline, ctx)
    }

    /// Clears the inbound callback. The retain root is dropped; Rust will
    /// receive a null callback pointer.
    public static func clearInboundCallback() {
        c_phantom_set_inbound_callback(nil, nil)
        currentBox = nil
    }

    /// Returns the current stats snapshot, or nil on FFI / decode failure.
    public static func stats() -> Stats? {
        guard let raw = c_phantom_get_stats() else { return nil }
        defer { c_phantom_free_string(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Stats.self, from: data)
    }

    /// Returns log entries with `seq > sinceSeq`. Pass `-1` to fetch all
    /// buffered entries. Returns `[]` on FFI / decode failure.
    public static func logs(sinceSeq: Int64 = -1) -> [LogEntry] {
        guard let raw = c_phantom_get_logs(sinceSeq) else { return [] }
        defer { c_phantom_free_string(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([LogEntry].self, from: data)) ?? []
    }

    /// Sets the Rust log level. Accepts "trace", "debug", "info"
    /// (warn/error are collapsed to info on the Rust side).
    public static func setLogLevel(_ level: String) {
        level.withCString { c_phantom_set_log_level($0) }
    }

    /// Parses a `ghs://` conn string into its components.
    /// Returns nil on any parse error.
    public static func parseConnString(_ input: String) -> ParsedConnConfig? {
        let raw: UnsafeMutablePointer<CChar>? = input.withCString { c_phantom_parse_conn_string($0) }
        guard let raw else { return nil }
        defer { c_phantom_free_string(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParsedConnConfig.self, from: data)
    }

    /// Computes inverted VPN routes for split-routing. `directCidrs` is a
    /// newline-separated list of CIDRs that should bypass the tunnel.
    /// Returns `[]` if the Rust side fails to compute or if decoding fails.
    public static func computeVpnRoutes(directCidrs: String) -> [IPRoute] {
        let raw: UnsafeMutablePointer<CChar>? = directCidrs.withCString { c_phantom_compute_vpn_routes($0) }
        guard let raw else { return [] }
        defer { c_phantom_free_string(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([IPRoute].self, from: data)) ?? []
    }
}
