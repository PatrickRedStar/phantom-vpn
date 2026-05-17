package com.ghoststream.vpn.ui.dashboard

import android.app.Activity
import android.net.VpnService
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
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
import com.ghoststream.vpn.ui.components.isTabletExpanded
import com.ghoststream.vpn.ui.components.isTabletPortrait
import com.ghoststream.vpn.ui.components.serifAccent
import com.ghoststream.vpn.ui.theme.C
import kotlinx.coroutines.delay
import androidx.compose.runtime.LaunchedEffect as LE

@Composable
fun DashboardScreen(viewModel: DashboardViewModel = viewModel()) {
    val vpnState by viewModel.vpnState.collectAsStateWithLifecycle()
    val stats by viewModel.stats.collectAsStateWithLifecycle()
    val statusFrame by viewModel.statusFrame.collectAsStateWithLifecycle()
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

    // Rolling RX/TX sparkline (1 sample per real second) — fed by push-based statusFrame
    val rxBuffer = remember { mutableStateListOf<Float>() }
    val txBuffer = remember { mutableStateListOf<Float>() }
    var lastRx by remember { mutableStateOf(0L) }
    var lastTx by remember { mutableStateOf(0L) }
    var accRx by remember { mutableStateOf(0f) }
    var accTx by remember { mutableStateOf(0f) }

    // "Tunnel is up-ish" — any state where bytes can still move on the wire.
    // Stale / Throttled / Reconnecting all keep the StatusFrame buffer alive
    // so the user can see post-mortem context; we just don't lie about it
    // being healthy.
    fun VpnState.isLive(): Boolean = this is VpnState.Connected ||
        this is VpnState.Stale ||
        this is VpnState.Throttled ||
        this is VpnState.Reconnecting

    // Accumulate deltas from each StatusFrame push
    LE(statusFrame.bytesRx, statusFrame.bytesTx, vpnState) {
        if (vpnState.isLive()) {
            val dRx = (statusFrame.bytesRx - lastRx).coerceAtLeast(0)
            val dTx = (statusFrame.bytesTx - lastTx).coerceAtLeast(0)
            accRx += dRx.toFloat()
            accTx += dTx.toFloat()
            lastRx = statusFrame.bytesRx
            lastTx = statusFrame.bytesTx
        } else {
            rxBuffer.clear(); txBuffer.clear()
            lastRx = 0; lastTx = 0
            accRx = 0f; accTx = 0f
        }
    }

    // Flush accumulated bytes into buffer once per second
    LE(vpnState, scopeWindowSecs) {
        if (vpnState.isLive()) {
            while (true) {
                delay(1000)
                rxBuffer.add(accRx)
                txBuffer.add(accTx)
                accRx = 0f
                accTx = 0f
                while (rxBuffer.size > scopeWindowSecs) rxBuffer.removeAt(0)
                while (txBuffer.size > scopeWindowSecs) txBuffer.removeAt(0)
            }
        }
    }

    // Animated mux bars — only shimmer when *real* RX traffic is flowing.
    // Previously shimmered on a timer whenever Connected; now ticked off
    // when rateRxBps drops to zero so the user sees a static row when the
    // tunnel is silent (the visual representation of "stale"). v0.24.0.
    val barHeights = remember { mutableStateListOf(0.72f, 0.58f, 0.86f, 0.44f, 0.64f, 0.38f, 0.72f, 0.52f) }
    LE(vpnState) {
        while (vpnState.isLive()) {
            delay(700)
            // statusFrame.rateRxBps is the EMA bits/sec from runtime. >0
            // means actual data arrived in the last few ticks.
            if (statusFrame.rateRxBps > 0.0) {
                for (i in barHeights.indices) {
                    barHeights[i] =
                        (barHeights[i] + (Math.random().toFloat() - 0.5f) * 0.4f)
                            .coerceIn(0.2f, 0.95f)
                }
            }
        }
    }

    val headerMeta = when (vpnState) {
        is VpnState.Connected   -> "${activeProfile?.serverName?.take(12) ?: ""} · ${timerText}"
        is VpnState.Stale       -> "stale · ${(vpnState as VpnState.Stale).idleRxSecs}s idle"
        is VpnState.Throttled   -> "throttled · ${(vpnState as VpnState.Throttled).currentKbps} kbps"
        is VpnState.Reconnecting -> {
            val rs = vpnState as VpnState.Reconnecting
            "reconnecting · ${rs.attempt}/8" + (rs.nextDelaySecs?.let { " · ${it}s" } ?: "")
        }
        is VpnState.Connecting  -> "connecting"
        is VpnState.Error       -> "error"
        else                    -> "standby"
    }
    val metaPulse = vpnState is VpnState.Connected ||
        vpnState is VpnState.Connecting ||
        vpnState is VpnState.Stale ||
        vpnState is VpnState.Throttled ||
        vpnState is VpnState.Reconnecting

    // Pull the state name only (not bytes/timer) for the TalkBack live
    // announcement. The visible HeaderMeta shows the full info including
    // rapidly-changing values; this invisible Text triggers a polite
    // announcement only when the *state name* changes (Connected → Stale →
    // Reconnecting), avoiding TalkBack chatter every ~250 ms when bytes
    // tick over. v0.25.1. Inline Russian literals — string resources
    // a11y_state_* aren't shipped yet and adding them is out of scope.
    val stateLabel = when (vpnState) {
        is VpnState.Connected    -> "Подключено"
        is VpnState.Stale        -> "Канал замолчал"
        is VpnState.Throttled    -> "Скорость ограничена"
        is VpnState.Reconnecting -> "Переподключаемся"
        is VpnState.Connecting   -> "Подключение"
        is VpnState.Error        -> "Ошибка соединения"
        else                     -> "Ожидание"
    }

    // ── Per-screen layout branching (v0.26.1) ────────────────────────────
    // All shared state is captured above (rxBuffer/txBuffer/lastRx/lastTx/
    // accRx/accTx/scopeWindowSecs/barHeights). MainActivity declares
    // `configChanges="orientation|screenSize|...|screenLayout"` so rotation
    // does NOT recreate the Activity — Compose keeps `remember { ... }`
    // state across rotation regardless of which branch renders.
    val isExpanded = isTabletExpanded()
    val isMediumP  = isTabletPortrait()

    // ── Section composables — captured lambdas read enclosing state ──────
    // Defined inside DashboardScreen so they can pull profile/stats/
    // viewModel/buffers without prop drilling. Each one is the building
    // block reused across the three layouts.
    val stateHeadlineSection: @Composable () -> Unit = {
        Column(Modifier.padding(horizontal = 22.dp, vertical = 16.dp).padding(top = 12.dp)) {
            Text(
                text = stringResource(R.string.lbl_tunnel_state).uppercase(),
                style = com.ghoststream.vpn.ui.theme.GsText.labelMono,
                color = C.textFaint,
            )
            Spacer(Modifier.height(10.dp))
            AnimatedContent(
                targetState = vpnState,
                transitionSpec = {
                    (fadeIn() + slideInVertically { it / 3 }) togetherWith
                        (fadeOut() + slideOutVertically { -it / 3 })
                },
                label = "state_headline",
            ) { state ->
                val (verb, tail) = when (state) {
                    is VpnState.Connected     -> stringResource(R.string.state_transmitting_verb) to stringResource(R.string.state_period)
                    is VpnState.Stale         -> stringResource(R.string.state_stale_verb) to " ${state.idleRxSecs}s${stringResource(R.string.state_period)}"
                    is VpnState.Throttled     -> stringResource(R.string.state_throttled_verb) to " ${state.currentKbps} kbps${stringResource(R.string.state_period)}"
                    is VpnState.Reconnecting  -> stringResource(R.string.state_reconnecting_verb) to " ${state.attempt}/8${stringResource(R.string.state_ellipsis)}"
                    is VpnState.Connecting    -> stringResource(R.string.state_tuning_verb) to stringResource(R.string.state_ellipsis)
                    is VpnState.Error         -> stringResource(R.string.state_lost_verb) to " ${stringResource(R.string.state_signal_word)}${stringResource(R.string.state_period)}"
                    is VpnState.Disconnecting -> stringResource(R.string.state_tuning_verb) to stringResource(R.string.state_ellipsis)
                    else                      -> stringResource(R.string.state_standby_verb) to stringResource(R.string.state_period)
                }
                val accent = when (state) {
                    is VpnState.Connected      -> C.signal
                    is VpnState.Stale          -> C.warn
                    is VpnState.Throttled      -> C.warn
                    is VpnState.Reconnecting   -> C.danger
                    is VpnState.Error          -> C.danger
                    is VpnState.Connecting,
                    is VpnState.Disconnecting  -> C.warn
                    else                       -> C.textDim
                }
                Text(
                    text = serifAccent(verb, tail, accent),
                    style = com.ghoststream.vpn.ui.theme.GsText.stateHeadline,
                    color = C.bone,
                )
            }
        }
    }

    val timerRowSection: @Composable () -> Unit = {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 22.dp).padding(bottom = 14.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.Bottom,
        ) {
            Text(
                // Timer keeps running across Connected/Stale/Throttled —
                // the session is the same wall-clock event even if the
                // wire went quiet. v0.24.0.
                text = if (vpnState.isLive()) timerText else "--:--:--",
                style = com.ghoststream.vpn.ui.theme.GsText.ticker,
                color = when (vpnState) {
                    is VpnState.Connected -> C.bone
                    is VpnState.Stale,
                    is VpnState.Throttled -> C.warn
                    is VpnState.Reconnecting -> C.danger
                    else -> C.textFaint
                },
            )
            Text(
                text = stringResource(R.string.lbl_session).uppercase(),
                style = com.ghoststream.vpn.ui.theme.GsText.labelMonoSmall,
                color = C.textFaint,
            )
        }
    }

    val emptyHintSection: @Composable () -> Unit = {
        if (activeProfile == null && vpnState is VpnState.Disconnected) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 22.dp, vertical = 8.dp)
                    .background(C.bgElev)
                    .border(1.dp, C.hair)
                    .padding(14.dp),
            ) {
                Text(
                    text = stringResource(R.string.hint_add_profile),
                    style = com.ghoststream.vpn.ui.theme.GsText.body,
                    color = C.textDim,
                )
            }
        }
    }

    val preflightSection: @Composable () -> Unit = {
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
    }

    val scopeCardSection: @Composable () -> Unit = {
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
    }

    val muxCardSection: @Composable () -> Unit = {
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
    }

    val kvCardSection: @Composable () -> Unit = {
        GhostCard(Modifier.padding(horizontal = 18.dp).padding(bottom = 12.dp)) {
            Column(Modifier.padding(horizontal = 14.dp, vertical = 4.dp)) {
                KvRow(
                    stringResource(R.string.kv_identity),
                    activeProfile?.name ?: "—",
                    C.bone,
                )
                DashedHairline()
                val relayActive = activeProfile?.relayEnabled == true && !activeProfile?.relayAddr.isNullOrBlank()
                KvRow(
                    stringResource(R.string.kv_route),
                    if (relayActive)
                        "${stringResource(R.string.kv_route_relay)} · ${activeProfile!!.relayAddr}"
                    else
                        stringResource(R.string.kv_route_direct),
                    if (relayActive) C.signal else C.bone,
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
    }

    // FAB bar — Stop button is available across *every* "VPN is up-ish"
    // state so the user can bail out of a degraded session without
    // toggling Airplane mode. v0.24.0: include Stale/Throttled/Reconnecting
    // alongside the legacy Connected/Connecting/Disconnecting.
    val fabSection: @Composable (Modifier) -> Unit = { fabModifier ->
        Box(fabModifier.fillMaxWidth().padding(horizontal = 18.dp).padding(bottom = 12.dp)) {
            val isConnectedOrBusy = vpnState is VpnState.Connected ||
                vpnState is VpnState.Stale ||
                vpnState is VpnState.Throttled ||
                vpnState is VpnState.Reconnecting ||
                vpnState is VpnState.Connecting ||
                vpnState is VpnState.Disconnecting
            GhostFab(
                text = if (isConnectedOrBusy) stringResource(R.string.action_disconnect) else stringResource(R.string.action_connect),
                outline = !isConnectedOrBusy,
                onClick = {
                    when (vpnState) {
                        is VpnState.Connected,
                        is VpnState.Stale,
                        is VpnState.Throttled,
                        is VpnState.Reconnecting,
                        is VpnState.Connecting -> viewModel.stopVpn()
                        else -> {
                            val perm = VpnService.prepare(context)
                            if (perm != null) vpnPermLauncher.launch(perm)
                            else viewModel.startVpn()
                        }
                    }
                },
            )
        }
    }

    Column(Modifier.fillMaxSize().background(C.bg)) {
        ScreenHeader(
            brand = stringResource(R.string.brand_stream),
            meta = { HeaderMeta(headerMeta, pulse = metaPulse) },
        )

        // Invisible TalkBack live region — announces only the state word,
        // not the changing bytes/timer in HeaderMeta. Rendered at 1.dp /
        // alpha 0 so Compose keeps it in the semantics tree without it
        // appearing on screen. v0.25.1.
        Text(
            text = stateLabel,
            modifier = Modifier
                .size(1.dp)
                .alpha(0f)
                .semantics {
                    liveRegion = LiveRegionMode.Polite
                    contentDescription = stateLabel
                },
        )

        when {
            // ── Expanded: tablet landscape / unfolded foldable ───────────
            // 2-col hero: left = STATE + SESSION + CONNECT pinned bottom.
            // right = SCOPE / MUX / KV stacked, independently scrollable.
            // Bottom-nav is replaced by NavigationDrawer at this width, so
            // no 80 dp tail padding is needed.
            isExpanded -> {
                Row(Modifier.weight(1f).fillMaxWidth()) {
                    // Left pane 42% — hero copy + CONNECT
                    Column(
                        modifier = Modifier
                            .weight(0.42f)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState()),
                    ) {
                        stateHeadlineSection()
                        timerRowSection()
                        emptyHintSection()
                        preflightSection()
                        Spacer(Modifier.weight(1f))
                        fabSection(Modifier)
                    }
                    // Vertical divider between panes
                    Box(
                        Modifier
                            .width(1.dp)
                            .fillMaxHeight()
                            .background(C.hair),
                    )
                    // Right pane 58% — telemetry cards
                    Column(
                        modifier = Modifier
                            .weight(0.58f)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState())
                            .padding(top = 16.dp),
                    ) {
                        scopeCardSection()
                        muxCardSection()
                        kvCardSection()
                        Spacer(Modifier.height(16.dp))
                    }
                }
            }

            // ── Medium portrait: tablet portrait (sw ≥ 600, w < 840) ─────
            // Single column, but max-content-width clamp 720 dp so 10"
            // portrait doesn't stretch lines to absurd lengths.
            isMediumP -> {
                Box(Modifier.weight(1f).fillMaxWidth()) {
                    Column(
                        modifier = Modifier
                            .widthIn(max = 720.dp)
                            .align(Alignment.TopCenter)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState()),
                    ) {
                        stateHeadlineSection()
                        timerRowSection()
                        emptyHintSection()
                        preflightSection()
                        scopeCardSection()
                        muxCardSection()
                        kvCardSection()
                        Spacer(Modifier.height(12.dp))
                        fabSection(Modifier)
                        // Bottom-nav is a NavigationRail on medium portrait
                        // (see rememberAdaptiveNavType), so no 80 dp tail
                        // padding needed.
                        Spacer(Modifier.height(16.dp))
                    }
                }
            }

            // ── Compact: phone, any orientation ──────────────────────────
            // Original layout — preserved verbatim including the 80 dp
            // tail spacer for the floating bottom NavigationBar.
            else -> {
                Column(Modifier.weight(1f).fillMaxWidth()) {
                    stateHeadlineSection()
                    timerRowSection()
                    emptyHintSection()
                    preflightSection()
                    scopeCardSection()
                    muxCardSection()
                    kvCardSection()
                    Spacer(Modifier.weight(1f))
                }
                fabSection(Modifier)
                Spacer(Modifier.height(80.dp))
            }
        }
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

