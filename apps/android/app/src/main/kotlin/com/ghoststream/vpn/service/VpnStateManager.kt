package com.ghoststream.vpn.service

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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

object VpnStateManager {
    private val _state = MutableStateFlow<VpnState>(VpnState.Disconnected)
    val state: StateFlow<VpnState> = _state.asStateFlow()

    fun update(newState: VpnState) {
        _state.value = newState
    }
}
