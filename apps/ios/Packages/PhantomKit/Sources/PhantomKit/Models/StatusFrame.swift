import Foundation

/// Codable mirror of the Rust `StatusFrame` from `crates/gui-ipc/src/lib.rs`.
/// Delivered via the status callback from `phantom_runtime_start`.
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
        reconnectNextDelaySecs: UInt32?
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
    }

    public static let disconnected = StatusFrame(
        state: .disconnected, sessionSecs: 0, bytesRx: 0, bytesTx: 0,
        rateRxBps: 0, rateTxBps: 0, nStreams: 0, streamsUp: 0,
        streamActivity: Array(repeating: 0, count: 16),
        rttMs: nil, tunAddr: nil, serverAddr: nil, sni: nil,
        lastError: nil, reconnectAttempt: nil, reconnectNextDelaySecs: nil
    )
}
