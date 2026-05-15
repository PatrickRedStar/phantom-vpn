package com.ghoststream.vpn.service

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import org.json.JSONObject
import java.time.Instant

sealed class VpnState {
    data object Disconnected : VpnState()
    data object Connecting : VpnState()
    /** Tunnel is up and traffic is fresh (idle_rx <= STALE threshold). */
    data class Connected(
        val since: Instant = Instant.now(),
        val serverName: String = "",
    ) : VpnState()
    /**
     * Tunnel reports `Connected` lifecycle but `health = Stale` from the
     * runtime — no RX for > 18 s. About to reconnect via RX_IDLE_TIMEOUT (45 s).
     * v0.24.0.
     */
    data class Stale(
        val since: Instant = Instant.now(),
        val serverName: String,
        val idleRxSecs: Int,
    ) : VpnState()
    /**
     * Tunnel up, traffic flowing, but bandwidth dropped to ≤20% of session
     * peak — DPI shaping suspected. v0.24.0.
     */
    data class Throttled(
        val since: Instant = Instant.now(),
        val serverName: String,
        val currentKbps: Long,
        val peakKbps: Long,
    ) : VpnState()
    /**
     * Runtime is between attempts. `attempt` is 1-based, `nextDelaySecs`
     * may be null between status frames. v0.24.0.
     */
    data class Reconnecting(
        val attempt: Int,
        val nextDelaySecs: Int?,
        val lastError: String?,
    ) : VpnState()
    data class Error(val message: String) : VpnState()
    data object Disconnecting : VpnState()
}

/**
 * Tunnel health classification mirrored from Rust `TunnelHealth`. New in
 * v0.24.0 — derived from connection state + idle_rx_secs + bandwidth_class.
 */
enum class TunnelHealth {
    HEALTHY, STALE, DEGRADED, RECONNECTING;

    companion object {
        fun fromJson(s: String?): TunnelHealth = when (s) {
            "stale" -> STALE
            "degraded" -> DEGRADED
            "reconnecting" -> RECONNECTING
            else -> HEALTHY
        }
    }
}

enum class BandwidthClass {
    NORMAL, THROTTLED;

    companion object {
        fun fromJson(s: String?): BandwidthClass =
            if (s == "throttled") THROTTLED else NORMAL
    }
}

/**
 * Push-based status frame from Rust. Updated by onStatusFrame().
 *
 * v0.24.0 adds: lastRxMs, lastTxMs, idleRxSecs, health, bandwidthClass,
 * reconnectAttempt, reconnectNextDelaySecs — used by the derived
 * `VpnState` flow in `VpnStateManager` to give the UI an honest signal
 * even when the underlying tunnel is silently dead.
 */
data class StatusFrameData(
    val state: String = "disconnected",
    val bytesRx: Long = 0,
    val bytesTx: Long = 0,
    val streamsUp: Int = 0,
    val nStreams: Int = 8,
    val sessionSecs: Long = 0,
    val rateRxBps: Double = 0.0,
    val rateTxBps: Double = 0.0,
    val lastRxMs: Long = 0,
    val lastTxMs: Long = 0,
    val idleRxSecs: Int = 0,
    val health: TunnelHealth = TunnelHealth.HEALTHY,
    val bandwidthClass: BandwidthClass = BandwidthClass.NORMAL,
    val reconnectAttempt: Int? = null,
    val reconnectNextDelaySecs: Int? = null,
    val lastError: String? = null,
    val serverAddr: String? = null,
    val sni: String? = null,
) {
    companion object {
        fun fromJson(json: String): StatusFrameData? = runCatching {
            val o = JSONObject(json)
            StatusFrameData(
                state = o.optString("state", "disconnected"),
                bytesRx = o.optLong("bytes_rx"),
                bytesTx = o.optLong("bytes_tx"),
                streamsUp = o.optInt("streams_up"),
                nStreams = o.optInt("n_streams", 8),
                sessionSecs = o.optLong("session_secs"),
                rateRxBps = o.optDouble("rate_rx_bps", 0.0),
                rateTxBps = o.optDouble("rate_tx_bps", 0.0),
                lastRxMs = o.optLong("last_rx_ms"),
                lastTxMs = o.optLong("last_tx_ms"),
                idleRxSecs = o.optInt("idle_rx_secs"),
                health = TunnelHealth.fromJson(if (o.has("health")) o.optString("health") else null),
                bandwidthClass = BandwidthClass.fromJson(if (o.has("bandwidth_class")) o.optString("bandwidth_class") else null),
                reconnectAttempt = if (o.has("reconnect_attempt") && !o.isNull("reconnect_attempt"))
                    o.optInt("reconnect_attempt") else null,
                reconnectNextDelaySecs = if (o.has("reconnect_next_delay_secs") && !o.isNull("reconnect_next_delay_secs"))
                    o.optInt("reconnect_next_delay_secs") else null,
                lastError = if (o.has("last_error") && !o.isNull("last_error"))
                    o.optString("last_error") else null,
                serverAddr = if (o.has("server_addr") && !o.isNull("server_addr"))
                    o.optString("server_addr") else null,
                sni = if (o.has("sni") && !o.isNull("sni")) o.optString("sni") else null,
            )
        }.getOrNull()
    }
}

/**
 * Push-based log frame from Rust. Emitted by onLogFrame().
 * v0.24.0: now carries category + fields per ADR 0008 LogFrame v2 so the
 * Android UI can render structured key/value pairs and filter by category.
 */
data class LogFrameData(
    val tsUnixMs: Long,
    val level: String,
    val msg: String,
    val category: String? = null,
    val fields: Map<String, String> = emptyMap(),
) {
    companion object {
        fun fromJson(json: String): LogFrameData? = runCatching {
            val o = JSONObject(json)
            val cat = if (o.has("category") && !o.isNull("category")) o.optString("category") else null
            val fields = mutableMapOf<String, String>()
            if (o.has("fields") && !o.isNull("fields")) {
                val fo = o.optJSONObject("fields")
                if (fo != null) {
                    val keys = fo.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        fields[k] = fo.optString(k, "")
                    }
                }
            }
            LogFrameData(
                tsUnixMs = o.optLong("ts_unix_ms"),
                level = o.optString("level", "INF"),
                msg = o.optString("msg", ""),
                category = cat,
                fields = fields,
            )
        }.getOrNull()
    }
}

object VpnStateManager {
    private val _state = MutableStateFlow<VpnState>(VpnState.Disconnected)
    val state: StateFlow<VpnState> = _state.asStateFlow()

    /** Latest StatusFrame from Rust (telemetry: bytes, rates, streams). */
    private val _statusFrame = MutableStateFlow(StatusFrameData())
    val statusFrame: StateFlow<StatusFrameData> = _statusFrame.asStateFlow()

    /** Log frames from Rust, emitted as a hot flow (replay=0, buffer=256). */
    private val _logFrames = MutableSharedFlow<LogFrameData>(extraBufferCapacity = 256)
    val logFrames: SharedFlow<LogFrameData> = _logFrames.asSharedFlow()

    /**
     * Process-scoped coroutine scope for state derivation. Singleton-safe
     * because `VpnStateManager` is itself a process-wide object; the scope
     * lives for the lifetime of the app process.
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /**
     * Honest UI state derived from (lifecycle, StatusFrame).
     *
     * `state` (the lifecycle flow) reports the connector's intent — what
     * `nativeStart` decided to do. `statusFrame.health` reports what the
     * Rust runtime *actually observes* on the wire. When the two disagree,
     * the runtime view wins — that's the whole point of v0.24.0's
     * "honest UI" overhaul: never lie about Connected when no RX has
     * arrived for 20+ seconds.
     */
    val derivedVpnState: StateFlow<VpnState> = combine(_state, _statusFrame) { lifecycle, frame ->
        deriveUiState(lifecycle, frame)
    }.stateIn(
        scope,
        SharingStarted.Eagerly,
        deriveUiState(_state.value, _statusFrame.value),
    )

    fun update(newState: VpnState) {
        val prev = _state.value
        _state.value = newState
        // Emit lifecycle log so the user's log screen shows state transitions.
        val msg = when (newState) {
            is VpnState.Connecting -> "VPN: подключение..."
            is VpnState.Connected -> "VPN: подключено (${newState.serverName})"
            is VpnState.Stale -> "VPN: тишина в канале (${newState.idleRxSecs}s)"
            is VpnState.Throttled -> "VPN: канал зажат до ${newState.currentKbps} kbps"
            is VpnState.Reconnecting -> "VPN: переподключение (попытка ${newState.attempt})"
            is VpnState.Disconnecting -> "VPN: отключение..."
            is VpnState.Disconnected -> "VPN: отключено"
            is VpnState.Error -> "VPN: ошибка — ${newState.message}"
        }
        if (prev::class != newState::class) {
            emitLifecycleLog("INFO", msg)
        }
    }

    /** Emit an app-side log entry visible on the logs screen. */
    fun emitLifecycleLog(level: String, msg: String) {
        val lvl = when (level) {
            "ERROR" -> "ERR"
            "WARN" -> "WRN"
            "INFO" -> "INF"
            "DEBUG" -> "DBG"
            else -> level
        }
        _logFrames.tryEmit(LogFrameData(
            tsUnixMs = System.currentTimeMillis(),
            level = lvl,
            msg = msg,
        ))
    }

    fun pushStatusFrame(json: String) {
        StatusFrameData.fromJson(json)?.let { _statusFrame.value = it }
    }

    fun pushLogFrame(json: String) {
        LogFrameData.fromJson(json)?.let { _logFrames.tryEmit(it) }
    }

    fun resetStatus() {
        _statusFrame.value = StatusFrameData()
    }
}

/**
 * Pure derivation: (lifecycle, statusFrame) → UI state.
 *
 * - Disconnected / Connecting / Disconnecting / Error: pass-through, no
 *   honesty applied — lifecycle is authoritative for these.
 * - Connected: consult `statusFrame.health` and downgrade if needed.
 *
 * Reconnect signal: when the status frame ships a `reconnectAttempt`,
 * report `Reconnecting` regardless of lifecycle. The Rust supervisor
 * publishes this *before* sleeping between attempts, so we transition
 * the UI immediately instead of pretending we're still connected.
 */
internal fun deriveUiState(lifecycle: VpnState, frame: StatusFrameData): VpnState {
    // Reconnect from runtime always trumps lifecycle.
    if (frame.reconnectAttempt != null && lifecycle !is VpnState.Disconnected
        && lifecycle !is VpnState.Disconnecting
    ) {
        return VpnState.Reconnecting(
            attempt = frame.reconnectAttempt,
            nextDelaySecs = frame.reconnectNextDelaySecs,
            lastError = frame.lastError,
        )
    }
    return when (lifecycle) {
        is VpnState.Connected -> {
            when (frame.health) {
                TunnelHealth.STALE -> VpnState.Stale(
                    since = lifecycle.since,
                    serverName = lifecycle.serverName,
                    idleRxSecs = frame.idleRxSecs,
                )
                TunnelHealth.DEGRADED -> VpnState.Throttled(
                    since = lifecycle.since,
                    serverName = lifecycle.serverName,
                    currentKbps = (frame.rateRxBps / 1000.0).toLong(),
                    peakKbps = 0L, // peak isn't shipped in StatusFrame today; UI shows current only
                )
                TunnelHealth.RECONNECTING -> VpnState.Reconnecting(
                    attempt = frame.reconnectAttempt ?: 0,
                    nextDelaySecs = frame.reconnectNextDelaySecs,
                    lastError = frame.lastError,
                )
                TunnelHealth.HEALTHY -> lifecycle
            }
        }
        else -> lifecycle
    }
}
