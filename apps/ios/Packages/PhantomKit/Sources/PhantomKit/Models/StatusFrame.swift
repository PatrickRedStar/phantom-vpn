import Foundation

/// Fine-grained health classification for a `.connected` tunnel — mirrors
/// Rust `TunnelHealth` from `crates/gui-ipc/src/lib.rs`. When the underlying
/// transport is silent for >stale threshold (`.stale`), partially throttled
/// (`.degraded`) or mid-recovery (`.reconnecting`), the lifecycle state can
/// still be `.connected` while the UI signals an honest degraded status.
///
/// `.unknown` is the sentinel returned from `init(from:)` when the Rust
/// runtime ships a variant this build doesn't recognise (forward compat).
public enum TunnelHealth: String, Codable, Equatable {
    case healthy
    case stale
    case degraded
    case reconnecting
    /// Sentinel for unknown variants delivered by a newer runtime.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TunnelHealth(rawValue: raw) ?? .unknown
    }
}

/// Coarse bandwidth class — mirrors Rust `BandwidthClass` from
/// `crates/gui-ipc/src/lib.rs`. `.throttled` is set when sustained throughput
/// drops below ~20% of session peak while traffic is still flowing — typical
/// TSPU-128 DPI shaping signature (~128 kbit/s).
///
/// `.unknown` is the sentinel returned from `init(from:)` when the Rust
/// runtime ships a variant this build doesn't recognise (forward compat).
public enum BandwidthClass: String, Codable, Equatable {
    case normal
    case throttled
    /// Sentinel for unknown variants delivered by a newer runtime.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = BandwidthClass(rawValue: raw) ?? .unknown
    }
}

/// Codable mirror of the Rust `StatusFrame` from `crates/gui-ipc/src/lib.rs`.
/// Delivered via the status callback from `phantom_runtime_start`.
///
/// All v0.24.0 fields (`lastRxMs`, `lastTxMs`, `idleRxSecs`, `health`,
/// `bandwidthClass`) decode through `decodeIfPresent` so frames produced by
/// older runtimes (pre-ADR 0008) still round-trip cleanly.
public struct StatusFrame: Codable {
    public var state: ConnState
    public var sessionSecs: UInt64
    public var bytesRx: UInt64
    public var bytesTx: UInt64
    public var rateRxBps: Double
    public var rateTxBps: Double
    public var nStreams: UInt8
    public var streamsUp: UInt8
    public var streamActivity: [Float]   // 16 elements
    public var rttMs: UInt32?
    public var tunAddr: String?
    public var serverAddr: String?
    public var sni: String?
    public var lastError: String?
    public var reconnectAttempt: UInt32?
    public var reconnectNextDelaySecs: UInt32?
    /// Unix-ms timestamp of last byte received from server. `nil` if the
    /// runtime is too old to publish this. v0.24.0+.
    public var lastRxMs: Int64?
    /// Unix-ms timestamp of last byte transmitted to server. `nil` if the
    /// runtime is too old to publish this. v0.24.0+.
    public var lastTxMs: Int64?
    /// Seconds since `lastRxMs` (derived runtime-side so the UI doesn't have
    /// to do its own wall-clock math). `nil` if the runtime is too old.
    /// v0.24.0+.
    public var idleRxSecs: Double?
    /// Fine-grained health classification for `.connected` tunnels.
    /// `nil` if the runtime is too old. v0.24.0+.
    public var health: TunnelHealth?
    /// Coarse bandwidth class — `.throttled` flags suspected DPI shaping.
    /// `nil` if the runtime is too old. v0.24.0+.
    public var bandwidthClass: BandwidthClass?

    enum CodingKeys: String, CodingKey {
        case state
        case sessionSecs = "session_secs"
        case bytesRx = "bytes_rx"
        case bytesTx = "bytes_tx"
        case rateRxBps = "rate_rx_bps"
        case rateTxBps = "rate_tx_bps"
        case nStreams = "n_streams"
        case streamsUp = "streams_up"
        case streamActivity = "stream_activity"
        case rttMs = "rtt_ms"
        case tunAddr = "tun_addr"
        case serverAddr = "server_addr"
        case sni
        case lastError = "last_error"
        case reconnectAttempt = "reconnect_attempt"
        case reconnectNextDelaySecs = "reconnect_next_delay_secs"
        case lastRxMs = "last_rx_ms"
        case lastTxMs = "last_tx_ms"
        case idleRxSecs = "idle_rx_secs"
        case health
        case bandwidthClass = "bandwidth_class"
    }

    public init(
        state: ConnState,
        sessionSecs: UInt64,
        bytesRx: UInt64,
        bytesTx: UInt64,
        rateRxBps: Double,
        rateTxBps: Double,
        nStreams: UInt8,
        streamsUp: UInt8,
        streamActivity: [Float],
        rttMs: UInt32?,
        tunAddr: String?,
        serverAddr: String?,
        sni: String?,
        lastError: String?,
        reconnectAttempt: UInt32?,
        reconnectNextDelaySecs: UInt32?,
        lastRxMs: Int64? = nil,
        lastTxMs: Int64? = nil,
        idleRxSecs: Double? = nil,
        health: TunnelHealth? = nil,
        bandwidthClass: BandwidthClass? = nil
    ) {
        self.state = state
        self.sessionSecs = sessionSecs
        self.bytesRx = bytesRx
        self.bytesTx = bytesTx
        self.rateRxBps = rateRxBps
        self.rateTxBps = rateTxBps
        self.nStreams = nStreams
        self.streamsUp = streamsUp
        self.streamActivity = streamActivity
        self.rttMs = rttMs
        self.tunAddr = tunAddr
        self.serverAddr = serverAddr
        self.sni = sni
        self.lastError = lastError
        self.reconnectAttempt = reconnectAttempt
        self.reconnectNextDelaySecs = reconnectNextDelaySecs
        self.lastRxMs = lastRxMs
        self.lastTxMs = lastTxMs
        self.idleRxSecs = idleRxSecs
        self.health = health
        self.bandwidthClass = bandwidthClass
    }

    /// Custom decoder so older runtimes (or partial frames) survive parsing.
    /// Mandatory v1 fields still throw on absence; only the post-v0.24.0
    /// additions are tolerant of missing keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try c.decode(ConnState.self, forKey: .state)
        self.sessionSecs = try c.decode(UInt64.self, forKey: .sessionSecs)
        self.bytesRx = try c.decode(UInt64.self, forKey: .bytesRx)
        self.bytesTx = try c.decode(UInt64.self, forKey: .bytesTx)
        self.rateRxBps = try c.decode(Double.self, forKey: .rateRxBps)
        self.rateTxBps = try c.decode(Double.self, forKey: .rateTxBps)
        self.nStreams = try c.decode(UInt8.self, forKey: .nStreams)
        self.streamsUp = try c.decode(UInt8.self, forKey: .streamsUp)
        self.streamActivity = try c.decode([Float].self, forKey: .streamActivity)
        self.rttMs = try c.decodeIfPresent(UInt32.self, forKey: .rttMs)
        self.tunAddr = try c.decodeIfPresent(String.self, forKey: .tunAddr)
        self.serverAddr = try c.decodeIfPresent(String.self, forKey: .serverAddr)
        self.sni = try c.decodeIfPresent(String.self, forKey: .sni)
        self.lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        self.reconnectAttempt = try c.decodeIfPresent(UInt32.self, forKey: .reconnectAttempt)
        self.reconnectNextDelaySecs = try c.decodeIfPresent(UInt32.self, forKey: .reconnectNextDelaySecs)
        self.lastRxMs = try c.decodeIfPresent(Int64.self, forKey: .lastRxMs)
        self.lastTxMs = try c.decodeIfPresent(Int64.self, forKey: .lastTxMs)
        self.idleRxSecs = try c.decodeIfPresent(Double.self, forKey: .idleRxSecs)
        self.health = try c.decodeIfPresent(TunnelHealth.self, forKey: .health)
        self.bandwidthClass = try c.decodeIfPresent(BandwidthClass.self, forKey: .bandwidthClass)
    }

    public static let disconnected = StatusFrame(
        state: .disconnected, sessionSecs: 0, bytesRx: 0, bytesTx: 0,
        rateRxBps: 0, rateTxBps: 0, nStreams: 0, streamsUp: 0,
        streamActivity: Array(repeating: 0, count: 16),
        rttMs: nil, tunAddr: nil, serverAddr: nil, sni: nil,
        lastError: nil, reconnectAttempt: nil, reconnectNextDelaySecs: nil,
        lastRxMs: nil, lastTxMs: nil, idleRxSecs: nil,
        health: nil, bandwidthClass: nil
    )
}
