package com.ghoststream.vpn.ui.dashboard

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.filled.Settings
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.draw.drawBehind
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
import com.ghoststream.vpn.ui.theme.AccentTeal
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.LocalGhostColors
import com.ghoststream.vpn.ui.theme.RedError
import com.ghoststream.vpn.ui.theme.StatDlColor
import com.ghoststream.vpn.ui.theme.StatPkColor
import com.ghoststream.vpn.ui.theme.StatSeColor
import com.ghoststream.vpn.ui.theme.StatUlColor
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
    val gc           = LocalGhostColors.current

    val context     = LocalContext.current
    val isAndroidTv = remember { context.packageManager.hasSystemFeature("android.software.leanback") }
    val focusReq    = remember { FocusRequester() }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { if (it.resultCode == Activity.RESULT_OK) viewModel.startVpn() }

    LaunchedEffect(Unit) {
        if (isAndroidTv) runCatching { focusReq.requestFocus() }
    }

    // ── Animations ──────────────────────────────────────────────────────────
    val inf = rememberInfiniteTransition(label = "ghost")

    // Connected: ghost float (3.8s)
    val floatY by inf.animateFloat(
        0f, -7f,
        infiniteRepeatable(tween(3800, easing = EaseInOut), RepeatMode.Reverse),
        label = "float",
    )
    // Connected: glow pulse (2.8s) — scale + opacity
    val glowScale by inf.animateFloat(
        0.96f, 1.08f,
        infiniteRepeatable(tween(2800, easing = EaseInOut), RepeatMode.Reverse),
        label = "glow_scale",
    )
    val glowAlphaAnim by inf.animateFloat(
        0.72f, 1f,
        infiniteRepeatable(tween(2800, easing = EaseInOut), RepeatMode.Reverse),
        label = "glow_alpha",
    )
    // Connecting: breathe (1.1s)
    val breathe by inf.animateFloat(
        1f, 1.04f,
        infiniteRepeatable(tween(1100, easing = EaseInOut), RepeatMode.Reverse),
        label = "breathe",
    )
    // Connecting: glow (1.1s)
    val connectGlowScale by inf.animateFloat(
        0.94f, 1.08f,
        infiniteRepeatable(tween(1100, easing = EaseInOut), RepeatMode.Reverse),
        label = "connect_glow_scale",
    )
    val connectGlowAlpha by inf.animateFloat(
        0.45f, 1f,
        infiniteRepeatable(tween(1100, easing = EaseInOut), RepeatMode.Reverse),
        label = "connect_glow_alpha",
    )
    // Connecting: ring spin (1.15s)
    val ringAngle by inf.animateFloat(
        0f, 360f,
        infiniteRepeatable(tween(1150, easing = LinearEasing), RepeatMode.Restart),
        label = "ring_spin",
    )

    // Per-state derived values
    val ghostTY = if (vpnState is VpnState.Connected) floatY else 0f
    val ghostScale = when (vpnState) {
        is VpnState.Connecting -> breathe
        is VpnState.Disconnected, is VpnState.Disconnecting -> 0.96f
        else -> 1f
    }
    val ghostAlpha = when (vpnState) {
        is VpnState.Disconnected, is VpnState.Disconnecting -> 0.78f
        is VpnState.Connecting -> 0.88f
        else -> 1f
    }
    val glowColor = when (vpnState) {
        is VpnState.Connected -> GreenConnected
        is VpnState.Connecting -> AccentPurple
        is VpnState.Error -> RedError
        else -> Color.Transparent
    }
    val currentGlowAlpha = when (vpnState) {
        is VpnState.Connected -> glowAlphaAnim
        is VpnState.Connecting -> connectGlowAlpha
        is VpnState.Disconnected, is VpnState.Disconnecting -> 0.18f
        else -> 0f
    }
    val currentGlowScale = when (vpnState) {
        is VpnState.Connected -> glowScale
        is VpnState.Connecting -> connectGlowScale
        is VpnState.Disconnected, is VpnState.Disconnecting -> 0.92f
        else -> 1f
    }
    val timerAlpha = when (vpnState) {
        is VpnState.Connected -> 1f
        is VpnState.Connecting -> 0.72f
        else -> 0.42f
    }
    val statsAlpha = when (vpnState) {
        is VpnState.Connected -> 1f
        is VpnState.Connecting -> 0.82f
        else -> 0.5f
    }
    val srvAlpha = when (vpnState) {
        is VpnState.Connected -> 1f
        is VpnState.Connecting -> 0.82f
        else -> 0.55f
    }
    val showRing = vpnState is VpnState.Connecting
    // Desaturate ghost when disconnected
    val ghostSaturation = when (vpnState) {
        is VpnState.Disconnected, is VpnState.Disconnecting -> 0.7f
        else -> 1f
    }

    val mascotSize = if (isAndroidTv) 200.dp else 130.dp
    val hPad = if (isAndroidTv) 64.dp else 16.dp

    // ── Layout ──────────────────────────────────────────────────────────────
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    0f to gc.pageBase,
                    0.15f to gc.pageBase,
                    1f to gc.pageBase,
                )
            )
            .drawBehind {
                // Radial glow top — purple
                drawCircle(
                    brush = Brush.radialGradient(
                        listOf(gc.pageGlowA, Color.Transparent),
                        center = Offset(size.width / 2, 0f),
                        radius = size.width * 0.9f,
                    ),
                    radius = size.width * 0.9f,
                    center = Offset(size.width / 2, 0f),
                )
                // Radial glow bottom — teal
                drawCircle(
                    brush = Brush.radialGradient(
                        listOf(gc.pageGlowB, Color.Transparent),
                        center = Offset(size.width / 2, size.height),
                        radius = size.width * 0.8f,
                    ),
                    radius = size.width * 0.8f,
                    center = Offset(size.width / 2, size.height),
                )
            }
            .verticalScroll(rememberScrollState())
            .padding(horizontal = hPad, vertical = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(if (isAndroidTv) 48.dp else 8.dp))

        // ── Ghost section ───────────────────────────────────────────────────
        Box(contentAlignment = Alignment.Center) {
            // Radial glow behind ghost
            if (currentGlowAlpha > 0f) {
                Box(
                    modifier = Modifier
                        .size(mascotSize + 56.dp)
                        .graphicsLayer {
                            scaleX = currentGlowScale
                            scaleY = currentGlowScale
                        }
                        .background(
                            Brush.radialGradient(
                                listOf(
                                    glowColor.copy(alpha = currentGlowAlpha * 0.40f),
                                    glowColor.copy(alpha = currentGlowAlpha * 0.08f),
                                    Color.Transparent,
                                ),
                            ),
                        ),
                )
            }

            // Ghost ring (Connecting state)
            if (showRing) {
                Canvas(
                    modifier = Modifier.size(mascotSize + 20.dp),
                ) {
                    val strokeWidth = 3.dp.toPx()
                    val ringSize = size.minDimension
                    rotate(ringAngle) {
                        // Outer ring: teal top-right, purple left
                        drawArc(
                            color = AccentTeal.copy(alpha = 0.85f),
                            startAngle = -90f,
                            sweepAngle = 120f,
                            useCenter = false,
                            style = Stroke(strokeWidth, cap = StrokeCap.Round),
                            size = androidx.compose.ui.geometry.Size(ringSize, ringSize),
                        )
                        drawArc(
                            color = AccentPurple.copy(alpha = 0.7f),
                            startAngle = 30f,
                            sweepAngle = 120f,
                            useCenter = false,
                            style = Stroke(strokeWidth, cap = StrokeCap.Round),
                            size = androidx.compose.ui.geometry.Size(ringSize, ringSize),
                        )
                        drawArc(
                            color = Color.White.copy(alpha = 0.55f),
                            startAngle = 150f,
                            sweepAngle = 60f,
                            useCenter = false,
                            style = Stroke(strokeWidth * 0.7f, cap = StrokeCap.Round),
                            size = androidx.compose.ui.geometry.Size(ringSize, ringSize),
                        )
                    }
                }
            }

            // Ghost image
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
                    colorFilter = if (ghostSaturation < 1f) {
                        ColorFilter.colorMatrix(
                            androidx.compose.ui.graphics.ColorMatrix().apply { setToSaturation(ghostSaturation) }
                        )
                    } else null,
                )
            }
        }

        Spacer(Modifier.height(4.dp))

        // Connection status pill
        ConnectionPill(vpnState = vpnState)

        // State hint
        val hint = when (vpnState) {
            is VpnState.Disconnected -> "Нажми на духа, чтобы переключить VPN"
            is VpnState.Error -> "Нажми, чтобы попробовать снова"
            else -> null
        }
        if (hint != null) {
            Spacer(Modifier.height(8.dp))
            Text(
                text = hint,
                fontSize = 10.sp,
                color = gc.textTertiary,
                textAlign = TextAlign.Center,
                letterSpacing = 0.2.sp,
            )
        }

        Spacer(Modifier.height(6.dp))

        // Timer
        Text(
            text = timerText,
            fontFamily = FontFamily.Monospace,
            fontSize = 38.sp,
            fontWeight = FontWeight.Light,
            letterSpacing = 3.sp,
            color = gc.textPrimary.copy(alpha = timerAlpha),
        )

        Spacer(Modifier.height(8.dp))

        // Server card
        ServerCard(
            flagEmoji = countryFlag,
            host = config.serverAddr.ifBlank { "—" },
            subscriptionText = subText,
            modifier = Modifier.graphicsLayer { alpha = srvAlpha },
        )

        Spacer(Modifier.height(11.dp))

        // ── Stats 2 × 2 ────────────────────────────────────────────────────
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .graphicsLayer { alpha = statsAlpha },
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                StatCard(
                    iconChar = "↓",
                    label = "Download",
                    value = FormatUtils.formatSpeed(stats.bytesRx, stats.elapsedSecs),
                    subValue = FormatUtils.formatBytes(stats.bytesRx),
                    iconTint = StatDlColor,
                    iconBg = StatDlColor.copy(alpha = 0.15f),
                    modifier = Modifier.weight(1f),
                )
                StatCard(
                    iconChar = "↑",
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
                    iconChar = "⏱",
                    label = "Сессия",
                    value = timerText,
                    iconTint = StatSeColor,
                    iconBg = StatSeColor.copy(alpha = 0.15f),
                    modifier = Modifier.weight(1f),
                )
                StatCard(
                    iconChar = "◈",
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

        // ── Navigation cubes ────────────────────────────────────────────────
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
