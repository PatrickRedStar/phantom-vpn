package com.ghoststream.vpn.ui.dashboard

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.R
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.ui.components.ConnectionPill
import com.ghoststream.vpn.ui.components.CubeButton
import com.ghoststream.vpn.ui.components.ServerCard
import com.ghoststream.vpn.ui.components.StatCard
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.PageBase
import com.ghoststream.vpn.ui.theme.RedError
import com.ghoststream.vpn.ui.theme.StatDlColor
import com.ghoststream.vpn.ui.theme.StatPkColor
import com.ghoststream.vpn.ui.theme.StatSeColor
import com.ghoststream.vpn.ui.theme.StatUlColor
import com.ghoststream.vpn.ui.theme.TextTertiary
import com.ghoststream.vpn.util.FormatUtils

@Composable
fun DashboardScreen(
    viewModel: DashboardViewModel = viewModel(),
    onOpenLogs: () -> Unit = {},
    onOpenSettings: () -> Unit = {},
) {
    val vpnState     by viewModel.vpnState.collectAsStateWithLifecycle()
    val stats        by viewModel.stats.collectAsStateWithLifecycle()
    val timerText    by viewModel.timerText.collectAsStateWithLifecycle()
    val subText      by viewModel.subscriptionText.collectAsStateWithLifecycle()
    val config       by viewModel.config.collectAsStateWithLifecycle()
    val countryFlag  by viewModel.countryFlag.collectAsStateWithLifecycle()

    val context     = LocalContext.current
    val isAndroidTv = remember { context.packageManager.hasSystemFeature("android.software.leanback") }
    val focusReq    = remember { FocusRequester() }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { if (it.resultCode == Activity.RESULT_OK) viewModel.startVpn() }

    LaunchedEffect(Unit) {
        if (isAndroidTv) runCatching { focusReq.requestFocus() }
    }

    // ── Animations ────────────────────────────────────────────────────────────
    val inf = rememberInfiniteTransition(label = "ghost")

    val floatY by inf.animateFloat(            // Connected: ghost float
        0f, -8f,
        infiniteRepeatable(tween(1900, easing = EaseInOut), RepeatMode.Reverse),
        label = "float",
    )
    val glowA by inf.animateFloat(             // Connected: glow pulse
        0.18f, 0.62f,
        infiniteRepeatable(tween(1400, easing = EaseInOut), RepeatMode.Reverse),
        label = "glow",
    )
    val breathe by inf.animateFloat(           // Connecting: breathe scale
        1f, 1.05f,
        infiniteRepeatable(tween(1100, easing = EaseInOut), RepeatMode.Reverse),
        label = "breathe",
    )

    // Per-state derived values
    val ghostTY     = if (vpnState is VpnState.Connected) floatY else 0f
    val ghostScale  = when (vpnState) {
        is VpnState.Connecting                           -> breathe
        is VpnState.Disconnected, is VpnState.Disconnecting -> 0.96f
        else                                             -> 1f
    }
    val ghostAlpha  = when (vpnState) {
        is VpnState.Disconnected, is VpnState.Disconnecting -> 0.72f
        is VpnState.Connecting                           -> 0.88f
        else                                             -> 1f
    }
    val glowColor   = when (vpnState) {
        is VpnState.Connected  -> GreenConnected
        is VpnState.Connecting -> AccentPurple
        is VpnState.Error      -> RedError
        else                   -> Color.Transparent
    }
    val glowAlpha   = when (vpnState) {
        is VpnState.Connected  -> glowA
        is VpnState.Connecting -> 0.28f
        else                   -> 0f
    }
    val timerAlpha  = when (vpnState) {
        is VpnState.Connected  -> 1f
        is VpnState.Connecting -> 0.72f
        else                   -> 0.42f
    }
    val statsAlpha  = when (vpnState) {
        is VpnState.Connected  -> 1f
        is VpnState.Connecting -> 0.82f
        else                   -> 0.5f
    }
    val srvAlpha    = when (vpnState) {
        is VpnState.Connected  -> 1f
        is VpnState.Connecting -> 0.82f
        else                   -> 0.55f
    }

    val mascotSize  = if (isAndroidTv) 200.dp else 130.dp
    val hPad        = if (isAndroidTv) 64.dp  else 16.dp

    // ── Layout ────────────────────────────────────────────────────────────────
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(PageBase)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = hPad, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(if (isAndroidTv) 48.dp else 8.dp))

        // ── Ghost section ─────────────────────────────────────────────────────
        Box(contentAlignment = Alignment.Center) {
            // Radial glow behind ghost
            if (glowAlpha > 0f) {
                Box(
                    modifier = Modifier
                        .size(mascotSize + 56.dp)
                        .background(
                            Brush.radialGradient(
                                listOf(
                                    glowColor.copy(alpha = glowAlpha * 0.40f),
                                    glowColor.copy(alpha = glowAlpha * 0.08f),
                                    Color.Transparent,
                                ),
                            ),
                        ),
                )
            }

            // Ghost image (clickable, animated)
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(mascotSize)
                    .focusRequester(focusReq)
                    .focusable()
                    .onKeyEvent { ev ->
                        if (ev.type == KeyEventType.KeyUp &&
                            (ev.key == Key.DirectionCenter || ev.key == Key.Enter)
                        ) { onToggle(context, vpnState, permLauncher, viewModel); true }
                        else false
                    }
                    .graphicsLayer {
                        translationY = ghostTY
                        scaleX = ghostScale; scaleY = ghostScale
                        alpha = ghostAlpha
                    }
                    .clickable { onToggle(context, vpnState, permLauncher, viewModel) },
            ) {
                Image(
                    painter = painterResource(R.drawable.ghost_mascot),
                    contentDescription = "GhostStream",
                    contentScale = ContentScale.Fit,
                    modifier = Modifier.fillMaxSize(),
                )
                if (vpnState is VpnState.Connecting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(mascotSize),
                        color = AccentPurple,
                        strokeWidth = 2.5.dp,
                        trackColor = AccentPurple.copy(alpha = 0.12f),
                    )
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        // Connection status pill
        ConnectionPill(vpnState = vpnState)

        // State hint (only when not connected)
        val hint = when (vpnState) {
            is VpnState.Disconnected -> "Нажми на духа, чтобы включить VPN"
            is VpnState.Error        -> "Нажми, чтобы попробовать снова"
            else                     -> null
        }
        if (hint != null) {
            Spacer(Modifier.height(6.dp))
            Text(
                text = hint,
                style = MaterialTheme.typography.bodySmall,
                color = TextTertiary,
                textAlign = TextAlign.Center,
                letterSpacing = 0.2.sp,
            )
        }

        Spacer(Modifier.height(8.dp))

        // Timer — always visible, dimmed when disconnected
        Text(
            text = timerText,
            style = MaterialTheme.typography.headlineLarge.copy(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Light,
                letterSpacing = 3.sp,
            ),
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = timerAlpha),
        )

        Spacer(Modifier.height(8.dp))

        // Server card — always visible, dimmed when disconnected
        ServerCard(
            flagEmoji = countryFlag,
            host = config.serverAddr.ifBlank { "—" },
            subscriptionText = subText,
            modifier = Modifier.graphicsLayer { alpha = srvAlpha },
        )

        Spacer(Modifier.height(12.dp))

        // ── Stats 2 × 2 ───────────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .graphicsLayer { alpha = statsAlpha },
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatCard(
                    icon = Icons.Filled.ArrowDownward,
                    label = "Download",
                    value = FormatUtils.formatSpeed(stats.bytesRx, stats.elapsedSecs),
                    subValue = FormatUtils.formatBytes(stats.bytesRx),
                    iconTint = StatDlColor,
                    iconBg = StatDlColor.copy(alpha = 0.15f),
                    modifier = Modifier.weight(1f),
                )
                StatCard(
                    icon = Icons.Filled.ArrowUpward,
                    label = "Upload",
                    value = FormatUtils.formatSpeed(stats.bytesTx, stats.elapsedSecs),
                    subValue = FormatUtils.formatBytes(stats.bytesTx),
                    iconTint = StatUlColor,
                    iconBg = StatUlColor.copy(alpha = 0.15f),
                    modifier = Modifier.weight(1f),
                )
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatCard(
                    icon = Icons.Filled.Timer,
                    label = "Сессия",
                    value = timerText,
                    iconTint = StatSeColor,
                    iconBg = StatSeColor.copy(alpha = 0.15f),
                    modifier = Modifier.weight(1f),
                )
                StatCard(
                    icon = Icons.Filled.SwapVert,
                    label = "Пакеты",
                    value = "${stats.pktsRx + stats.pktsTx}",
                    subValue = "${stats.pktsRx} / ${stats.pktsTx}",
                    iconTint = StatPkColor,
                    iconBg = StatPkColor.copy(alpha = 0.15f),
                    modifier = Modifier.weight(1f),
                )
            }
        }

        Spacer(Modifier.height(14.dp))

        // ── Navigation cubes ──────────────────────────────────────────────────
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CubeButton(
                icon = Icons.AutoMirrored.Filled.Article,
                label = "Логи",
                sublabel = "Подключение, трафик, ошибки",
                iconTint = BlueDebug,
                iconBg = BlueDebug.copy(alpha = 0.15f),
                onClick = onOpenLogs,
                modifier = Modifier.weight(1f),
            )
            CubeButton(
                icon = Icons.Filled.Settings,
                label = "Параметры",
                sublabel = "DNS, маршруты, сертификат",
                iconTint = AccentPurple,
                iconBg = AccentPurple.copy(alpha = 0.15f),
                onClick = onOpenSettings,
                modifier = Modifier.weight(1f),
            )
        }

        Spacer(Modifier.height(24.dp))
    }
}

private fun onToggle(
    context: android.content.Context,
    vpnState: VpnState,
    launcher: ActivityResultLauncher<Intent>,
    viewModel: DashboardViewModel,
) {
    when (vpnState) {
        is VpnState.Connected, is VpnState.Connecting -> viewModel.stopVpn()
        else -> {
            val perm = VpnService.prepare(context)
            if (perm != null) launcher.launch(perm) else viewModel.startVpn()
        }
    }
}
