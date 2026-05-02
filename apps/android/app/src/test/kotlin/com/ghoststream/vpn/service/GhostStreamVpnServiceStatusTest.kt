package com.ghoststream.vpn.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GhostStreamVpnServiceStatusTest {
    @Test
    fun connectedStatusPromotesConnectingUiState() {
        val frame = StatusFrameData(state = "connected")

        assertTrue(shouldPromoteStatusFrameToConnected(VpnState.Connecting, frame))
    }

    @Test
    fun connectedStatusDoesNotRefreshAlreadyConnectedUiState() {
        val frame = StatusFrameData(state = "connected")

        assertFalse(
            shouldPromoteStatusFrameToConnected(
                VpnState.Connected(serverName = "tls.nl2.bikini-bottom.com"),
                frame,
            ),
        )
    }

    @Test
    fun connectedStatusDoesNotResurrectDisconnectedUiState() {
        val frame = StatusFrameData(state = "connected")

        assertFalse(shouldPromoteStatusFrameToConnected(VpnState.Disconnected, frame))
    }

    @Test
    fun connectedStatusDoesNotResurrectErrorUiState() {
        val frame = StatusFrameData(state = "connected")

        assertFalse(shouldPromoteStatusFrameToConnected(VpnState.Error("boom"), frame))
    }

    @Test
    fun connectedStatusDoesNotInterruptDisconnectingUiState() {
        val frame = StatusFrameData(state = "connected")

        assertFalse(shouldPromoteStatusFrameToConnected(VpnState.Disconnecting, frame))
    }

    @Test
    fun nonConnectedStatusDoesNotPromoteConnectingUiState() {
        val frame = StatusFrameData(state = "reconnecting")

        assertFalse(shouldPromoteStatusFrameToConnected(VpnState.Connecting, frame))
    }
}
