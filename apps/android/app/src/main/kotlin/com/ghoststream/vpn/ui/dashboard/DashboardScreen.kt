package com.ghoststream.vpn.ui.dashboard

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
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
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.windowInsetsPadding
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
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
import com.ghoststream.vpn.ui.components.PulseDot
import com.ghoststream.vpn.ui.components.isTabletExpanded
import com.ghoststream.vpn.ui.components.isTabletPortrait
import com.ghoststream.vpn.ui.components.phosphorAura
import com.ghoststream.vpn.ui.components.serifAccent
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.LocalIsDark
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
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

    // v0.27.0 (A3): runtime POST_NOTIFICATIONS request (Android 13+). The
    // result doesn't gate the connection — we just want heads-up alerts to be
    // visible. Requested once during first-connect onboarding.
    val notifPermLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* granted or not — connection proceeds regardless */ }

    // Подсказка «что это такое»: пара (заголовок, текст) или null.
    // Пользователь просил, чтобы по надписям на Потоке можно было тапнуть и
    // узнать, что они означают.
    var explain by remember { mutableStateOf<Pair<Int, Int>?>(null) }

    // Scope window (tap to cycle: 1m → 5m → 30m → 1h).
    // v0.28.1: выбор запоминается между запусками — раньше всегда сбрасывался
    // на 1m, и приходилось переключать заново после каждого старта.
    val prefsStore = remember { com.ghoststream.vpn.data.PreferencesStore(context.applicationContext) }
    val savedScopeWindow by prefsStore.scopeWindowSecs.collectAsStateWithLifecycle(initialValue = 60)
    var scopeWindowSecs by remember { mutableIntStateOf(60) }
    // Подхватываем сохранённое значение, когда DataStore его отдал
    LE(savedScopeWindow) { scopeWindowSecs = savedScopeWindow }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
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

    // Mux bars — driven by real per-stream activity from the runtime.
    // `statusFrame.streamActivity` is 0..1 per live stream (length == nStreams
    // when shipped). We keep a local animated copy so the bars shimmer while
    // RX traffic is actually flowing, but the source of truth — bar count and
    // baseline heights — is the runtime frame, never a hardcoded list. When
    // the runtime hasn't shipped activity yet we fall back to nStreams flat
    // bars. v0.27.0: honest infographic (was hardcoded 8 bars + 8/8 label).
    val nStreams = statusFrame.nStreams.coerceIn(1, 16)
    val barHeights = remember { mutableStateListOf<Float>() }
    // Re-sync bar count + baseline to the runtime activity array whenever it
    // changes shape (reconnect with a different core count, first frame, etc.).
    LE(statusFrame.streamActivity, nStreams) {
        val act = statusFrame.streamActivity
        val target = if (act.isNotEmpty()) act.size else nStreams
        when {
            barHeights.size > target -> while (barHeights.size > target) barHeights.removeAt(barHeights.size - 1)
            barHeights.size < target -> while (barHeights.size < target) barHeights.add(0.4f)
        }
        if (act.isNotEmpty()) {
            for (i in barHeights.indices) {
                barHeights[i] = act.getOrElse(i) { 0f }.coerceIn(0f, 1f)
            }
        }
    }
    LE(vpnState) {
        while (vpnState.isLive()) {
            delay(700)
            // statusFrame.rateRxBps is the EMA bits/sec from runtime. >0
            // means actual data arrived in the last few ticks — shimmer the
            // live bars around their runtime baseline so motion reads as
            // "traffic". When silent (Stale) the bars freeze.
            if (statusFrame.rateRxBps > 0.0 && barHeights.isNotEmpty()) {
                val liveCount = statusFrame.streamsUp.coerceIn(0, barHeights.size)
                for (i in 0 until liveCount) {
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
    // Flex Mode: null = обычная поза; иначе — доля высоты окна над шарниром
    val tabletopRatio by com.ghoststream.vpn.ui.components.rememberTabletopHingeRatio()

    // ── Section composables — captured lambdas read enclosing state ──────
    // Defined inside DashboardScreen so they can pull profile/stats/
    // viewModel/buffers without prop drilling. Each one is the building
    // block reused across the three layouts.
    val dnsHealth by com.ghoststream.vpn.service.DnsHealthMonitor.state.collectAsStateWithLifecycle()

    // A tunnel that carries bytes but resolves no names is not a working tunnel,
    // so the headline has to say so. Previously it read a green "Передача." with
    // 8/8 streams while nothing opened, which is what kept the 2026-07-31 DNS
    // failure invisible. Only override once the tunnel is actually up — during
    // Connecting/Error the tunnel state is the more useful thing to show.
    val dnsDead = dnsHealth is com.ghoststream.vpn.service.DnsHealth.Dead &&
        (vpnState is VpnState.Connected || vpnState is VpnState.Stale || vpnState is VpnState.Throttled)

    val stateHeadlineSection: @Composable () -> Unit = {
        Column(Modifier.padding(horizontal = 22.dp, vertical = 16.dp).padding(top = 12.dp)) {
            Text(
                text = stringResource(R.string.lbl_tunnel_state).uppercase(),
                style = com.ghoststream.vpn.ui.theme.GsText.labelMono,
                color = C.textFaint,
            )
            Spacer(Modifier.height(10.dp))
            AnimatedContent(
                targetState = vpnState to dnsDead,
                transitionSpec = {
                    (fadeIn() + slideInVertically { it / 3 }) togetherWith
                        (fadeOut() + slideOutVertically { -it / 3 })
                },
                label = "state_headline",
            ) { (state, noNames) ->
                // `noNames` wins over the tunnel state: bytes are moving but the
                // tunnel is unusable, and that is the more important fact.
                val (verb, tail) = when {
                    noNames                        -> stringResource(R.string.state_no_names_verb) to stringResource(R.string.state_period)
                    state is VpnState.Connected    -> stringResource(R.string.state_transmitting_verb) to stringResource(R.string.state_period)
                    state is VpnState.Stale        -> stringResource(R.string.state_stale_verb) to " ${state.idleRxSecs}s${stringResource(R.string.state_period)}"
                    state is VpnState.Throttled    -> stringResource(R.string.state_throttled_verb) to " ${state.currentKbps} kbps${stringResource(R.string.state_period)}"
                    state is VpnState.Reconnecting -> stringResource(R.string.state_reconnecting_verb) to " ${state.attempt}/8${stringResource(R.string.state_ellipsis)}"
                    state is VpnState.Connecting   -> stringResource(R.string.state_tuning_verb) to stringResource(R.string.state_ellipsis)
                    state is VpnState.Error        -> stringResource(R.string.state_lost_verb) to " ${stringResource(R.string.state_signal_word)}${stringResource(R.string.state_period)}"
                    state is VpnState.Disconnecting -> stringResource(R.string.state_tuning_verb) to stringResource(R.string.state_ellipsis)
                    else                           -> stringResource(R.string.state_standby_verb) to stringResource(R.string.state_period)
                }
                val accent = when {
                    noNames                        -> C.danger
                    state is VpnState.Connected    -> C.signal
                    state is VpnState.Stale        -> C.warn
                    state is VpnState.Throttled    -> C.warn
                    state is VpnState.Reconnecting -> C.danger
                    state is VpnState.Error        -> C.danger
                    state is VpnState.Connecting ||
                        state is VpnState.Disconnecting -> C.warn
                    else                           -> C.textDim
                }
                // ADR 0015: фосфорное свечение вокруг активного глагола.
                // Shadow красится в accent — хвост тоже попадает под blur,
                // но при alpha 0.35 это читается как общий ореол, не грязь.
                Text(
                    text = serifAccent(verb, tail, accent),
                    style = com.ghoststream.vpn.ui.theme.GsText.stateHeadline.copy(
                        shadow = androidx.compose.ui.graphics.Shadow(
                            color = accent.copy(alpha = 0.35f),
                            blurRadius = 24f,
                        ),
                    ),
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

    // ADR 0015: осциллограф и мультиплекс — ОДНА карточка с внутренним
    // разделителем (меньше рамок, телеметрия читается единым блоком).
    val telemetryCardSection: @Composable () -> Unit = {
        GhostCard(Modifier.padding(horizontal = 20.dp).padding(bottom = 12.dp)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
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
                        val next = when (scopeWindowSecs) {
                            60 -> 300
                            300 -> 1800
                            1800 -> 3600
                            3600 -> 60
                            else -> 60
                        }
                        scopeWindowSecs = next
                        // Буферы НЕ чистим: при расширении окна история остаётся
                        // видимой, при сужении лишние сэмплы обрежет флаш-цикл.
                        // Раньше график обнулялся на каждое переключение.
                        scope.launch { runCatching { prefsStore.setScopeWindowSecs(next) } }
                    },
                )
            }
            ScopeChart(rxSamples = rxBuffer.toList(), txSamples = txBuffer.toList())
            // inset-разделитель между осциллографом и мультиплексом
            Box(
                Modifier.padding(horizontal = 16.dp).padding(top = 6.dp)
                    .height(1.dp).fillMaxWidth()
                    .background(C.bone.copy(alpha = 0.06f)),
            )
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    stringResource(R.string.lbl_stream_multiplex).uppercase(),
                    style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
                    color = C.textDim,
                )
                val live = vpnState.isLive()
                val up = statusFrame.streamsUp
                val total = statusFrame.nStreams
                Text(
                    text = if (live)
                        String.format(stringResource(R.string.lbl_streams_up), up, total)
                    else "—",
                    style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
                    // Red label when some streams are down (Degraded), lime
                    // when all N are up; dimmed while standby.
                    color = when {
                        !live -> C.textDim
                        total > 0 && up < total -> C.danger
                        else -> C.signal
                    },
                )
            }
            MuxBars(
                heights = barHeights.toList(),
                // Only flag dead streams (red) while the tunnel is live; in
                // standby the streams concept doesn't apply, so all bars stay
                // neutral.
                liveCount = if (vpnState.isLive())
                    statusFrame.streamsUp.coerceIn(0, barHeights.size)
                else barHeights.size,
                animate = vpnState.isLive(),
            )
        }
    }

    // ADR 0015: «остров» — DNS-индикатор первой строкой + KV-строки с
    // inset-разделителями (паттерн настроек One UI). Бывшие networkCard +
    // kvCard слиты в одну поверхность.
    val kvCardSection: @Composable () -> Unit = {
        val dns = dnsHealth
        GhostCard(Modifier.padding(horizontal = 20.dp).padding(bottom = 12.dp)) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable {
                            explain = R.string.explain_dns_t to R.string.explain_dns_d
                        }
                        .padding(vertical = 10.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = stringResource(R.string.kv_dns),
                        style = com.ghoststream.vpn.ui.theme.GsText.labelMono,
                        color = C.textFaint,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        val dotColor = when (dns) {
                            is com.ghoststream.vpn.service.DnsHealth.Ok -> C.signal
                            is com.ghoststream.vpn.service.DnsHealth.Dead -> C.danger
                            else -> C.textFaint
                        }
                        com.ghoststream.vpn.ui.components.PulseDot(color = dotColor, size = 7.dp)
                        Spacer(Modifier.width(8.dp))
                        // Always name the server that is actually resolving. Prefer
                        // what the Rust data path SAW leaving the TUN over what is
                        // configured anywhere (см. комментарий в v0.27).
                        val observed = statusFrame?.dnsObserved?.let { raw ->
                            val ip = raw.substringBeforeLast(':')
                            val port = raw.substringAfterLast(':', "")
                            if (port == "853") "$ip · DoT" else ip
                        }
                        val configured = (dns as? com.ghoststream.vpn.service.DnsHealth.Ok)?.resolver
                            ?: (dns as? com.ghoststream.vpn.service.DnsHealth.Dead)?.resolver
                        val resolverName = observed
                            ?: configured
                            ?: stringResource(R.string.dns_via_tunnel)
                        Text(
                            text = when (dns) {
                                is com.ghoststream.vpn.service.DnsHealth.Ok ->
                                    stringResource(R.string.dns_ok, resolverName, dns.latencyMs)
                                is com.ghoststream.vpn.service.DnsHealth.Dead ->
                                    stringResource(R.string.dns_dead, resolverName)
                                com.ghoststream.vpn.service.DnsHealth.Probing ->
                                    stringResource(R.string.dns_probing)
                                else -> stringResource(R.string.kv_value_dash)
                            },
                            style = com.ghoststream.vpn.ui.theme.GsText.kvValue,
                            color = when (dns) {
                                is com.ghoststream.vpn.service.DnsHealth.Ok -> C.bone
                                is com.ghoststream.vpn.service.DnsHealth.Dead -> C.danger
                                else -> C.textDim
                            },
                        )
                    }
                }
                DashedHairline()
                KvRow(
                    stringResource(R.string.kv_identity),
                    activeProfile?.name ?: "—",
                    C.bone,
                ) { explain = R.string.explain_identity_t to R.string.explain_identity_d }
                DashedHairline()
                val relayActive = activeProfile?.relayEnabled == true && !activeProfile?.relayAddr.isNullOrBlank()
                KvRow(
                    stringResource(R.string.kv_route),
                    if (relayActive)
                        "${stringResource(R.string.kv_route_relay)} · ${activeProfile!!.relayAddr}"
                    else
                        stringResource(R.string.kv_route_direct),
                    if (relayActive) C.signal else C.bone,
                ) { explain = R.string.explain_route_t to R.string.explain_route_d }
                DashedHairline()
                KvRow(
                    stringResource(R.string.kv_assigned),
                    activeProfile?.tunAddr ?: "—",
                    C.bone,
                ) { explain = R.string.explain_assigned_t to R.string.explain_assigned_d }
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
                ) { explain = R.string.explain_sub_t to R.string.explain_sub_d }
            }
        }
    }

    // ADR 0015: транспорт — заполняет правую колонку на раскрытом экране.
    // Все значения реальные: H2/TLS 1.3 — инвариант протокола, остальное из
    // профиля и StatusFrame.
    val transportCardSection: @Composable () -> Unit = {
        val relayActive = activeProfile?.relayEnabled == true &&
            !activeProfile?.relayAddr.isNullOrBlank()
        GhostCard(Modifier.padding(horizontal = 20.dp).padding(bottom = 12.dp)) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) {
                Text(
                    text = stringResource(R.string.lbl_transport).uppercase(),
                    style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
                    color = C.textDim,
                )
                Spacer(Modifier.height(12.dp))
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    InfoPill("H2 · TLS 1.3") {
                        explain = R.string.explain_h2_t to R.string.explain_h2_d
                    }
                    InfoPill("mTLS") {
                        explain = R.string.explain_mtls_t to R.string.explain_mtls_d
                    }
                    if (relayActive) InfoPill("SNI passthrough", accent = true) {
                        explain = R.string.explain_sni_t to R.string.explain_sni_d
                    }
                    val n = statusFrame.nStreams
                    if (n > 0) InfoPill(String.format(stringResource(R.string.lbl_streams_n), n)) {
                        explain = R.string.explain_streams_t to R.string.explain_streams_d
                    }
                }
            }
        }
    }

    // ADR 0015: итоги сессии — остров для широких/вытянутых раскладок,
    // закрывает пустоту под телеметрией реальными счётчиками.
    val statsCardSection: @Composable () -> Unit = {
        GhostCard(Modifier.padding(horizontal = 20.dp).padding(bottom = 12.dp)) {
            Column(Modifier.padding(horizontal = 16.dp, vertical = 4.dp)) {
                KvRow(
                    stringResource(R.string.kv_rx_total),
                    formatBytes(statusFrame.bytesRx),
                    C.bone,
                )
                DashedHairline()
                KvRow(
                    stringResource(R.string.kv_tx_total),
                    formatBytes(statusFrame.bytesTx),
                    C.bone,
                )
                DashedHairline()
                KvRow(
                    stringResource(R.string.kv_exit),
                    activeProfile?.serverAddr?.substringBefore(':') ?: "—",
                    C.bone,
                )
            }
        }
    }

    // Shown only on a confirmed DNS failure. Names the culprit *only* when the
    // platform tells us one — the hostname comes from LinkProperties, never a
    // constant, and when strict Private DNS is off we say nothing about causes.
    val dnsBannerSection: @Composable () -> Unit = {
        val dns = dnsHealth
        if (dns is com.ghoststream.vpn.service.DnsHealth.Dead) {
            val ctx = LocalContext.current
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 18.dp)
                    .padding(bottom = 12.dp)
                    .border(1.dp, C.danger.copy(alpha = 0.45f), RoundedCornerShape(10.dp))
                    .padding(horizontal = 14.dp, vertical = 13.dp),
            ) {
                Text(
                    text = stringResource(R.string.dns_banner_title).uppercase(),
                    style = com.ghoststream.vpn.ui.theme.GsText.labelMono,
                    color = C.danger,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = dns.strictPrivateDnsHost?.let {
                        stringResource(R.string.dns_banner_private, it)
                    } ?: stringResource(R.string.dns_banner_generic),
                    style = com.ghoststream.vpn.ui.theme.GsText.kvValue,
                    color = C.textDim,
                )
                var showWhy by rememberSaveable { mutableStateOf(false) }
                if (showWhy) {
                    Spacer(Modifier.height(10.dp))
                    Text(
                        text = stringResource(R.string.dns_banner_why_text),
                        style = com.ghoststream.vpn.ui.theme.GsText.kvValue,
                        color = C.textFaint,
                    )
                }
                if (dns.strictPrivateDnsHost != null) {
                    Spacer(Modifier.height(12.dp))
                    Box(
                        Modifier
                            .fillMaxWidth()
                            .border(1.dp, C.warn, RoundedCornerShape(8.dp))
                            .clickable { openPrivateDnsSettings(ctx) }
                            .padding(vertical = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = stringResource(R.string.dns_banner_open_settings).uppercase(),
                            style = com.ghoststream.vpn.ui.theme.GsText.labelMono,
                            color = C.warn,
                        )
                    }
                }
                Spacer(Modifier.height(7.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .border(1.dp, C.hairBold, RoundedCornerShape(8.dp))
                        .clickable { showWhy = !showWhy }
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = stringResource(
                            if (showWhy) R.string.dns_banner_why_hide else R.string.dns_banner_why,
                        ).uppercase(),
                        style = com.ghoststream.vpn.ui.theme.GsText.labelMono,
                        color = C.textDim,
                    )
                }
            }
        }
    }

    // FAB bar — Stop button is available across *every* "VPN is up-ish"
    // state so the user can bail out of a degraded session without
    // toggling Airplane mode. v0.24.0: include Stale/Throttled/Reconnecting
    // alongside the legacy Connected/Connecting/Disconnecting.
    //
    // v0.27.0 (W5): button label + enabled gating reflect transitional state.
    // - Connecting / Reconnecting → "Подключение…", tap = cancel (stopVpn)
    // - Disconnecting → "Отключение…", **disabled** (no point re-tapping)
    // - Connected / Stale / Throttled → "Отключить"
    // - Disconnected / Error → "Подключить"
    // Prevents the start → stop → start thrash a rapid-fire user produced
    // before, where a tap in the Disconnecting state would slip past the
    // Service's tunnelGeneration guard via a fresh startVpn() launch.
    val fabSection: @Composable (Modifier) -> Unit = { fabModifier ->
        Box(fabModifier.fillMaxWidth().padding(horizontal = 20.dp).padding(bottom = 20.dp)) {
            val isConnectedOrBusy = vpnState is VpnState.Connected ||
                vpnState is VpnState.Stale ||
                vpnState is VpnState.Throttled ||
                vpnState is VpnState.Reconnecting ||
                vpnState is VpnState.Connecting ||
                vpnState is VpnState.Disconnecting
            val fabText = when (vpnState) {
                is VpnState.Connecting -> stringResource(R.string.action_connecting)
                is VpnState.Disconnecting -> stringResource(R.string.action_disconnecting)
                is VpnState.Connected,
                is VpnState.Stale,
                is VpnState.Throttled,
                is VpnState.Reconnecting -> stringResource(R.string.action_disconnect)
                else -> stringResource(R.string.action_connect)
            }
            val fabEnabled = vpnState !is VpnState.Disconnecting
            // ADR 0015: filled lime = призыв «Подключить» (standby), tonal =
            // спокойное «Отключить» пока туннель живёт. Инверсия старого маппинга.
            GhostFab(
                text = fabText,
                outline = isConnectedOrBusy,
                enabled = fabEnabled,
                onClick = {
                    when (vpnState) {
                        is VpnState.Connected,
                        is VpnState.Stale,
                        is VpnState.Throttled,
                        is VpnState.Reconnecting,
                        is VpnState.Connecting -> viewModel.stopVpn()
                        else -> {
                            // v0.27.0 (B4/A3): proactively request the
                            // battery-optimisation exemption (critical against
                            // Doze) and POST_NOTIFICATIONS on first Connect —
                            // once, gated by a prefs flag.
                            runFirstConnectOnboarding(context, notifPermLauncher::launch)
                            val perm = VpnService.prepare(context)
                            if (perm != null) vpnPermLauncher.launch(perm)
                            else viewModel.startVpn()
                        }
                    }
                },
            )
        }
    }

    // ADR 0015: дышащая аура за контентом — цвет от состояния туннеля
    val auraColor = when {
        dnsDead -> C.danger
        vpnState is VpnState.Connected -> C.signal
        vpnState is VpnState.Stale || vpnState is VpnState.Throttled ||
            vpnState is VpnState.Connecting || vpnState is VpnState.Disconnecting -> C.warn
        vpnState is VpnState.Reconnecting || vpnState is VpnState.Error -> C.danger
        else -> C.textDim
    }
    Column(
        Modifier.fillMaxSize().background(C.bg).phosphorAura(auraColor),
    ) {
        // На expanded бренд живёт только в drawer'е (ADR 0015: дубль убран);
        // контент начинается сразу с hero.
        if (!isExpanded) {
            ScreenHeader(
                brand = stringResource(R.string.brand_stream),
                meta = { HeaderMeta(headerMeta, pulse = metaPulse) },
            )
        }

        // Подсказка «что это такое» — по тапу на чип транспорта или KV-строку.
        explain?.let { (titleRes, bodyRes) ->
            com.ghoststream.vpn.ui.components.GhostDialog(
                onDismissRequest = { explain = null },
                title = stringResource(titleRes),
                content = {
                    Text(
                        text = stringResource(bodyRes),
                        style = com.ghoststream.vpn.ui.theme.GsText.body,
                        color = C.textDim,
                        lineHeight = androidx.compose.ui.unit.TextUnit(20f, androidx.compose.ui.unit.TextUnitType.Sp),
                    )
                },
                confirmButton = {
                    com.ghoststream.vpn.ui.components.GhostDialogButton(
                        stringResource(R.string.action_close),
                        onClick = { explain = null },
                        color = C.textDim,
                    )
                },
            )
        }

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
            // ── Flex Mode (ADR 0015): полусложенный шарнир, tabletop ──────
            // Верхняя половина — «экран»: hero + осциллограф. Нижняя, лежащая
            // на столе — «пульт»: DNS-остров, кнопка. Деление — по реальному
            // bounds шарнира (dp-пороги эту позу не видят в принципе).
            tabletopRatio != null -> {
                val ratio = tabletopRatio!!
                // верх — «экран»
                Column(Modifier.weight(ratio).fillMaxWidth()) {
                    val wide = androidx.compose.ui.platform.LocalConfiguration
                        .current.screenWidthDp >= 600
                    if (wide) {
                        Row(Modifier.weight(1f).fillMaxWidth()) {
                            Column(Modifier.weight(0.45f)) {
                                stateHeadlineSection()
                                timerRowSection()
                            }
                            Column(Modifier.weight(0.55f).padding(top = 8.dp)) {
                                telemetryCardSection()
                            }
                        }
                    } else {
                        stateHeadlineSection()
                        timerRowSection()
                        Box(Modifier.weight(1f).padding(top = 8.dp)) { telemetryCardSection() }
                    }
                }
                // зазор над сгибом — контент не заезжает на шарнир
                Spacer(Modifier.height(24.dp))
                // низ — «пульт»
                Column(
                    Modifier.weight(1f - ratio).fillMaxWidth()
                        .verticalScroll(rememberScrollState()),
                ) {
                    dnsBannerSection()
                    kvCardSection()
                    Spacer(Modifier.height(8.dp))
                    fabSection(Modifier)
                    Spacer(Modifier.height(12.dp))
                    Box(Modifier.windowInsetsPadding(WindowInsets.navigationBars))
                }
            }

            // ── Expanded: tablet landscape / unfolded foldable ───────────
            // 2-col hero: left = STATE + SESSION + CONNECT pinned bottom.
            // right = SCOPE / MUX / KV stacked, independently scrollable.
            // Bottom-nav is replaced by NavigationDrawer at this width, so
            // no 80 dp tail padding is needed.
            //
            // v0.26.4 polish:
            //   1. Theme-aware vertical divider — `C.hair` is barely visible
            //      on light paper, bump to `C.hairBold` + 1.5 dp width.
            //   2. Top-align both panes — right had top=16 dp, left had
            //      none, making the SCOPE card sit lower than the state
            //      headline. Both panes now share top=16 dp.
            //   3. FAB max-width 360 dp — on Tab S11 the 42% pane is ~445 dp
            //      wide and a full-width CONNECT button looks comically
            //      large. Centre it within a fillMaxWidth wrapper.
            // ADR 0015: hero на всю ширину (заголовок больше не рвётся посреди
            // слова в узкой колонке), под ним две колонки телеметрии, снизу док
            // с кнопкой. Дубль бренда убран — бренд живёт в drawer'е.
            isExpanded -> {
                // Hero row: заголовок слева, таймер справа
                Row(
                    Modifier.fillMaxWidth().padding(end = 24.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.Bottom,
                ) {
                    Column(Modifier.weight(1f)) {
                        stateHeadlineSection()
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text(
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
                        Spacer(Modifier.height(4.dp))
                        Text(
                            text = stringResource(R.string.lbl_session).uppercase(),
                            style = com.ghoststream.vpn.ui.theme.GsText.labelMonoSmall,
                            color = C.textFaint,
                        )
                    }
                }
                emptyHintSection()
                preflightSection()
                // Две колонки: слева телеметрия+итоги, справа KV-остров
                Row(Modifier.weight(1f).fillMaxWidth().padding(top = 10.dp)) {
                    Column(
                        modifier = Modifier
                            .weight(0.53f)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState()),
                    ) {
                        dnsBannerSection()
                        telemetryCardSection()
                        statsCardSection()
                        Spacer(Modifier.height(4.dp))
                        fabSection(Modifier.widthIn(max = 420.dp))
                        if (vpnState.isLive()) {
                            Text(
                                text = headerMeta.uppercase(),
                                style = com.ghoststream.vpn.ui.theme.GsText.labelMonoSmall,
                                color = C.textFaint,
                                modifier = Modifier.padding(start = 20.dp, bottom = 4.dp),
                            )
                        }
                        Spacer(Modifier.height(12.dp))
                    }
                    Column(
                        modifier = Modifier
                            .weight(0.47f)
                            .fillMaxHeight()
                            .verticalScroll(rememberScrollState()),
                    ) {
                        kvCardSection()
                        transportCardSection()
                        Spacer(Modifier.height(8.dp))
                    }
                }
                // v0.28.1: кнопка едет вместе с левой колонкой, а не висит в
                // приколоченном доке — на раскрытом экране док точно так же
                // обрезал контент по стыку со скроллом.
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
                        dnsBannerSection()
                        telemetryCardSection()
                        kvCardSection()
                        statsCardSection()
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
                // v0.28.1: кнопка едет ВНУТРИ прокрутки, как содержимое других
                // вкладок. Приколоченная к низу, она обрезала карточку на стыке
                // со скроллом — и обрез читался как «полоса» под контентом.
                Column(
                    Modifier.weight(1f).fillMaxWidth()
                        .verticalScroll(rememberScrollState()),
                ) {
                    stateHeadlineSection()
                    timerRowSection()
                    emptyHintSection()
                    preflightSection()
                    dnsBannerSection()
                    telemetryCardSection()
                    kvCardSection()
                    Spacer(Modifier.height(10.dp))
                    fabSection(Modifier)
                    // хвост под плавающую капсулу навигации
                    Spacer(Modifier.height(84.dp))
                }
            }
        }
    }
}

/**
 * Opens the closest system screen to the Private DNS setting.
 *
 * `android.settings.PRIVATE_DNS_SETTINGS` is **not** universal — verified absent
 * on Galaxy Z Fold 8 / One UI ("No activity found"), where the setting lives under
 * Connections → More connection settings. So resolve each candidate against the
 * package manager and launch the first one that actually exists, instead of
 * relying on startActivity throwing: a button that silently does nothing is worse
 * than one that lands a screen or two away.
 */
private fun openPrivateDnsSettings(ctx: Context) {
    val candidates = listOf(
        "android.settings.PRIVATE_DNS_SETTINGS",
        Settings.ACTION_WIRELESS_SETTINGS,
        Settings.ACTION_SETTINGS,
    )
    // Resolve everything FIRST, launch exactly once. The previous version started
    // an activity inside the loop, and with FLAG_ACTIVITY_NEW_TASK from an Activity
    // context One UI both raised the existing Settings task and created another —
    // two windows, the first collapsing before it finished drawing.
    val action = candidates.firstOrNull { a ->
        Intent(a).resolveActivity(ctx.packageManager) != null
    } ?: return
    val intent = Intent(action).apply {
        // NEW_TASK is only required when launching from a non-Activity context.
        // Adding it from an Activity is what produced the double window.
        if (ctx !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { ctx.startActivity(intent) }
}

/**
 * Инфо-pill карточки транспорта. Кликается — открывает подсказку «что это
 * такое»: термины вроде mTLS и SNI passthrough ничего не говорят человеку,
 * который просто хочет знать, защищён ли он.
 */
@Composable
private fun InfoPill(text: String, accent: Boolean = false, onClick: (() -> Unit)? = null) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clip(com.ghoststream.vpn.ui.theme.GsShapePill)
            .background(
                if (accent) C.signal.copy(alpha = 0.10f)
                else C.bone.copy(alpha = 0.045f),
            )
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 12.dp, vertical = 7.dp),
    ) {
        Text(
            text = text.uppercase(),
            style = com.ghoststream.vpn.ui.theme.GsText.chipText,
            color = if (accent) C.signal else C.textDim,
        )
        if (onClick != null) {
            Spacer(Modifier.width(6.dp))
            // Точка-подсказка: намекает, что чип можно нажать
            Text(
                text = "?",
                style = com.ghoststream.vpn.ui.theme.GsText.chipText,
                color = if (accent) C.signal.copy(alpha = 0.7f) else C.textFaint,
            )
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
private fun KvRow(
    key: String,
    value: String,
    valueColor: androidx.compose.ui.graphics.Color,
    onClick: (() -> Unit)? = null,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = 9.dp),
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

private fun formatBytes(bytes: Long): String {
    val b = bytes.coerceAtLeast(0)
    return when {
        b >= 1_000_000_000L -> "%.2f ГБ".format(b / 1_000_000_000f)
        b >= 1_000_000L     -> "%.0f МБ".format(b / 1_000_000f)
        b >= 1_000L         -> "%.0f КБ".format(b / 1_000f)
        else                -> "$b Б"
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

/**
 * v0.27.0 (B4/A3): one-shot first-connect onboarding. Runs at most once
 * (gated by PreferencesStore.onboardPromptsShown):
 *  - POST_NOTIFICATIONS (Android 13+) so the status + connection-loss alerts
 *    are actually visible.
 *  - REQUEST_IGNORE_BATTERY_OPTIMIZATIONS so Doze doesn't kill the tunnel
 *    when the phone is pocketed. Permission is already declared in the
 *    manifest; the system shows a yes/no dialog directly.
 * Neither prompt blocks the connection — it proceeds regardless of the answer.
 */
private fun runFirstConnectOnboarding(
    context: Context,
    requestNotifPermission: (String) -> Unit,
) {
    val prefs = com.ghoststream.vpn.data.PreferencesStore(context.applicationContext)
    if (prefs.onboardPromptsShownBlocking()) return

    // 1) Notification permission (Android 13+).
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        val granted = context.checkSelfPermission(
            android.Manifest.permission.POST_NOTIFICATIONS,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (!granted) {
            runCatching { requestNotifPermission(android.Manifest.permission.POST_NOTIFICATIONS) }
        }
    }

    // 2) Battery-optimisation exemption — critical against Doze.
    val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
    val exempt = pm?.isIgnoringBatteryOptimizations(context.packageName) ?: true
    if (!exempt) {
        runCatching {
            @Suppress("BatteryLife")
            val intent = Intent(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:${context.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        }.onFailure {
            // Fallback to the full list if the per-package action is missing.
            runCatching {
                context.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
        }
    }

    // Mark shown so we don't nag on every Connect.
    kotlinx.coroutines.runBlocking { runCatching { prefs.setOnboardPromptsShown(true) } }
}

