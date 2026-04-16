package com.ghoststream.vpn.ui.dashboard

import android.app.Activity
import android.net.VpnService
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.ui.components.DashedHairline
import com.ghoststream.vpn.ui.components.GhostCard
import com.ghoststream.vpn.ui.components.GhostFab
import com.ghoststream.vpn.ui.components.HeaderMeta
import com.ghoststream.vpn.ui.components.MuxBars
import com.ghoststream.vpn.ui.components.ScopeChart
import com.ghoststream.vpn.ui.components.ScreenHeader
import com.ghoststream.vpn.ui.components.serifAccent
import com.ghoststream.vpn.ui.theme.C
import kotlinx.coroutines.delay
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.LaunchedEffect as LE

@Composable
fun DashboardScreen(viewModel: DashboardViewModel = viewModel()) {
    val vpnState by viewModel.vpnState.collectAsStateWithLifecycle()
    val stats by viewModel.stats.collectAsStateWithLifecycle()
    val timerText by viewModel.timerText.collectAsStateWithLifecycle()
    val subscriptionText by viewModel.subscriptionText.collectAsStateWithLifecycle()
    val preflightWarning by viewModel.preflightWarning.collectAsStateWithLifecycle()

    val context = LocalContext.current
    val profilesStore = remember { ProfilesStore.getInstance(context.applicationContext) }
    val profiles by profilesStore.profiles.collectAsStateWithLifecycle()
    val activeId by profilesStore.activeId.collectAsStateWithLifecycle()
    val activeProfile = profiles.find { it.id == activeId } ?: profiles.firstOrNull()

    val vpnPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { if (it.resultCode == Activity.RESULT_OK) viewModel.startVpn() }

    // Scope window (tap to cycle: 1m → 5m → 30m → 1h)
    var scopeWindowSecs by remember { mutableIntStateOf(60) }
    val scopeLabel = when (scopeWindowSecs) {
        60 -> "1m"
        300 -> "5m"
        1800 -> "30m"
        3600 -> "1h"
        else -> "${scopeWindowSecs}s"
    }

    // Rolling RX/TX sparkline (delta per second)
    val rxBuffer = remember { mutableStateListOf<Float>() }
    val txBuffer = remember { mutableStateListOf<Float>() }
    var lastRx by remember { mutableStateOf(0L) }
    var lastTx by remember { mutableStateOf(0L) }
    LE(stats.bytesRx, stats.bytesTx, vpnState) {
        if (vpnState is VpnState.Connected) {
            val dRx = (stats.bytesRx - lastRx).coerceAtLeast(0)
            val dTx = (stats.bytesTx - lastTx).coerceAtLeast(0)
            rxBuffer.add(dRx.toFloat())
            txBuffer.add(dTx.toFloat())
            while (rxBuffer.size > scopeWindowSecs) rxBuffer.removeAt(0)
            while (txBuffer.size > scopeWindowSecs) txBuffer.removeAt(0)
            lastRx = stats.bytesRx
            lastTx = stats.bytesTx
        } else {
            rxBuffer.clear(); txBuffer.clear(); lastRx = 0; lastTx = 0
        }
    }

    // Animated mux bars (cosmetic — 8 bars shimmer while connected)
    val barHeights = remember { mutableStateListOf(0.72f, 0.58f, 0.86f, 0.44f, 0.64f, 0.38f, 0.72f, 0.52f) }
    LE(vpnState) {
        while (vpnState is VpnState.Connected) {
            delay(700)
            for (i in barHeights.indices) {
                barHeights[i] = (barHeights[i] + (Math.random().toFloat() - 0.5f) * 0.4f).coerceIn(0.2f, 0.95f)
            }
        }
    }

    val headerMeta = when (vpnState) {
        is VpnState.Connected  -> "${activeProfile?.serverName?.take(12) ?: ""} · ${timerText}"
        is VpnState.Connecting -> "connecting"
        is VpnState.Error      -> "error"
        else                   -> "standby"
    }
    val metaPulse = vpnState is VpnState.Connected || vpnState is VpnState.Connecting

    Column(Modifier.fillMaxSize().background(C.bg)) {
        ScreenHeader(
            brand = stringResource(R.string.brand_stream),
            meta = { HeaderMeta(headerMeta, pulse = metaPulse) },
        )

        Column(
            Modifier.weight(1f).fillMaxWidth(),
        ) {
            // State headline
            Column(Modifier.padding(horizontal = 22.dp, vertical = 16.dp).padding(top = 12.dp)) {
                Text(
                    text = stringResource(R.string.lbl_tunnel_state).uppercase(),
                    style = com.ghoststream.vpn.ui.theme.GsText.labelMono,
                    color = C.textFaint,
                )
                Spacer(Modifier.height(10.dp))
                val (verb, tail) = when (vpnState) {
                    is VpnState.Connected    -> stringResource(R.string.state_transmitting_verb) to stringResource(R.string.state_period)
                    is VpnState.Connecting   -> stringResource(R.string.state_tuning_verb) to stringResource(R.string.state_ellipsis)
                    is VpnState.Error        -> stringResource(R.string.state_lost_verb) to " ${stringResource(R.string.state_signal_word)}${stringResource(R.string.state_period)}"
                    is VpnState.Disconnecting-> stringResource(R.string.state_tuning_verb) to stringResource(R.string.state_ellipsis)
                    else                     -> stringResource(R.string.state_standby_verb) to stringResource(R.string.state_period)
                }
                val accent = when (vpnState) {
                    is VpnState.Connected -> C.signal
                    is VpnState.Error     -> C.danger
                    is VpnState.Connecting, is VpnState.Disconnecting -> C.warn
                    else                  -> C.textDim
                }
                Text(
                    text = serifAccent(verb, tail, accent),
                    style = com.ghoststream.vpn.ui.theme.GsText.stateHeadline,
                    color = C.bone,
                )
            }

            // Timer row
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 22.dp).padding(bottom = 14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Bottom,
            ) {
                Text(
                    text = if (vpnState is VpnState.Connected) timerText else "--:--:--",
                    style = com.ghoststream.vpn.ui.theme.GsText.ticker,
                    color = if (vpnState is VpnState.Connected) C.bone else C.textFaint,
                )
                Text(
                    text = stringResource(R.string.lbl_session).uppercase(),
                    style = com.ghoststream.vpn.ui.theme.GsText.labelMonoSmall,
                    color = C.textFaint,
                )
            }

            // Preflight warning
            if (preflightWarning != null) {
                Box(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = 18.dp, vertical = 6.dp)
                        .background(C.danger.copy(alpha = 0.1f))
                        .padding(10.dp),
                ) {
                    Text(
                        preflightWarning!!,
                        style = com.ghoststream.vpn.ui.theme.GsText.kvValue,
                        color = C.danger,
                    )
                }
            }

            // Scope card
            GhostCard(Modifier.padding(horizontal = 18.dp).padding(bottom = 12.dp)) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                        LabelValueLegend("RX", formatMbps(rxBuffer.lastOrNull() ?: 0f), C.signal)
                        LabelValueLegend("TX", formatMbps(txBuffer.lastOrNull() ?: 0f), C.warn)
                    }
                    Text(
                        text = scopeLabel.uppercase(),
                        style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
                        color = C.textFaint,
                        modifier = Modifier.clickable {
                            scopeWindowSecs = when (scopeWindowSecs) {
                                60 -> 300
                                300 -> 1800
                                1800 -> 3600
                                3600 -> 60
                                else -> 60
                            }
                            // Clear buffers when changing window
                            rxBuffer.clear()
                            txBuffer.clear()
                        },
                    )
                }
                Box(Modifier.height(1.dp).fillMaxWidth().background(C.hair))
                ScopeChart(rxSamples = rxBuffer.toList(), txSamples = txBuffer.toList())
            }

            // Mux card
            GhostCard(Modifier.padding(horizontal = 18.dp).padding(bottom = 12.dp)) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        stringResource(R.string.lbl_stream_multiplex).uppercase(),
                        style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
                        color = C.textDim,
                    )
                    Text(
                        text = String.format(stringResource(R.string.lbl_streams_up), 8, 8),
                        style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
                        color = C.signal,
                    )
                }
                Box(Modifier.height(1.dp).fillMaxWidth().background(C.hair))
                MuxBars(heights = barHeights.toList())
            }

            // KV card
            GhostCard(Modifier.padding(horizontal = 18.dp).padding(bottom = 12.dp)) {
                Column(Modifier.padding(horizontal = 14.dp, vertical = 4.dp)) {
                    KvRow(
                        stringResource(R.string.kv_identity),
                        activeProfile?.name ?: "—",
                        C.bone,
                    )
                    DashedHairline()
                    KvRow(
                        stringResource(R.string.kv_assigned),
                        activeProfile?.tunAddr ?: "—",
                        C.bone,
                    )
                    DashedHairline()
                    val subColour = when {
                        subscriptionText == null -> C.bone
                        subscriptionText!!.contains("⚠") -> C.danger
                        subscriptionText!!.contains("истек", true) -> C.danger
                        subscriptionText!!.contains("expire", true) -> C.danger
                        else -> C.signal
                    }
                    KvRow(
                        stringResource(R.string.kv_subscription),
                        subscriptionText ?: stringResource(R.string.kv_value_dash),
                        subColour,
                    )
                }
            }

            Spacer(Modifier.weight(1f))
        }

        // FAB bar
        Box(Modifier.fillMaxWidth().padding(horizontal = 18.dp).padding(bottom = 12.dp)) {
            val isConnectedOrBusy = vpnState is VpnState.Connected ||
                vpnState is VpnState.Connecting ||
                vpnState is VpnState.Disconnecting
            GhostFab(
                text = if (isConnectedOrBusy) stringResource(R.string.action_disconnect) else stringResource(R.string.action_connect),
                outline = !isConnectedOrBusy,
                onClick = {
                    when (vpnState) {
                        is VpnState.Connected, is VpnState.Connecting -> viewModel.stopVpn()
                        else -> {
                            val perm = VpnService.prepare(context)
                            if (perm != null) vpnPermLauncher.launch(perm)
                            else viewModel.startVpn()
                        }
                    }
                },
            )
        }

        Spacer(Modifier.height(80.dp))
    }
}

@Composable
private fun LabelValueLegend(label: String, value: String, dotColor: androidx.compose.ui.graphics.Color) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            Modifier
                .height(2.dp)
                .padding(end = 0.dp)
                .background(dotColor)
                .width(14.dp),
        )
        Spacer(Modifier.width(6.dp))
        Text(
            text = "$label ",
            style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
            color = C.textDim,
        )
        Text(
            text = value,
            style = com.ghoststream.vpn.ui.theme.GsText.kvValue,
            color = C.bone,
        )
    }
}

@Composable
private fun KvRow(key: String, value: String, valueColor: androidx.compose.ui.graphics.Color) {
    Row(
        Modifier.fillMaxWidth().padding(vertical = 9.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = key.uppercase(),
            style = com.ghoststream.vpn.ui.theme.GsText.labelMonoSmall,
            color = C.textFaint,
        )
        Text(
            text = value,
            style = com.ghoststream.vpn.ui.theme.GsText.kvValue,
            color = valueColor,
        )
    }
}

private fun formatMbps(bytesPerSec: Float): String {
    val mbps = (bytesPerSec * 8f) / 1_000_000f
    return when {
        mbps >= 100f -> "%.0f".format(mbps)
        mbps >= 10f  -> "%.1f".format(mbps)
        else         -> "%.2f".format(mbps)
    }
}

