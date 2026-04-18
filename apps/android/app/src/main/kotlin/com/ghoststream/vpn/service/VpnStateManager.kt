package com.ghoststream.vpn.service

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.time.Instant

sealed class VpnState {
    data object Disconnected : VpnState()
    data object Connecting : VpnState()
    data class Connected(
        val since: Instant = Instant.now(),
        val serverName: String = "",
    ) : VpnState()
    data class Error(val message: String) : VpnState()
    data object Disconnecting : VpnState()
}

/**
 * Push-based status frame from Rust. Updated by onStatusFrame().
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
            )
        }.getOrNull()
    }
}

/**
 * Push-based log frame from Rust. Emitted by onLogFrame().
 */
data class LogFrameData(
    val tsUnixMs: Long,
    val level: String,
    val msg: String,
) {
    companion object {
        fun fromJson(json: String): LogFrameData? = runCatching {
            val o = JSONObject(json)
            LogFrameData(
                tsUnixMs = o.optLong("ts_unix_ms"),
                level = o.optString("level", "INF"),
                msg = o.optString("msg", ""),
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

    fun update(newState: VpnState) {
        val prev = _state.value
        _state.value = newState
        // Emit lifecycle log so the user's log screen shows state transitions.
        val msg = when (newState) {
            is VpnState.Connecting -> "VPN: подключение..."
            is VpnState.Connected -> "VPN: подключено (${newState.serverName})"
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
