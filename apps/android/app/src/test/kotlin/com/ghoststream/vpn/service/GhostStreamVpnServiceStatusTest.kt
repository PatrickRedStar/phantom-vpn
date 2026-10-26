package com.ghoststream.vpn.service

import org.junit.Assert.assertEquals
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

    @Test
    fun staleReconnectCounterDoesNotHideError() {
        val frame = StatusFrameData(state = "reconnecting", reconnectAttempt = 3)

        assertEquals(VpnState.Error("доступ отозван"), deriveUiState(VpnState.Error("доступ отозван"), frame))
    }

    @Test
    fun deadStreamsAloneAreNotThrottled() {
        val connected = VpnState.Connected(serverName = "x")
        val frame = StatusFrameData(state = "connected", health = TunnelHealth.DEGRADED, streamsUp = 5)

        assertEquals(connected, deriveUiState(connected, frame))
    }

    @Test
    fun throttledBandwidthIsThrottled() {
        val frame = StatusFrameData(
            state = "connected",
            health = TunnelHealth.DEGRADED,
            bandwidthClass = BandwidthClass.THROTTLED,
        )

        assertTrue(deriveUiState(VpnState.Connected(serverName = "x"), frame) is VpnState.Throttled)
    }
}
