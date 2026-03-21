package com.ghoststream.vpn.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Security
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.RedError

@Composable
fun ConnectButton(
    state: VpnState,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val targetColor = when (state) {
        is VpnState.Disconnected  -> Color(0xFF616161)
        is VpnState.Connecting    -> AccentPurple
        is VpnState.Connected     -> GreenConnected
        is VpnState.Error         -> RedError
        is VpnState.Disconnecting -> Color(0xFF616161)
    }
    val animatedColor by animateColorAsState(targetColor, tween(300), label = "btn_color")

    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 1.12f,
        animationSpec = infiniteRepeatable(tween(800, easing = EaseInOut), RepeatMode.Reverse),
        label = "pulse_scale",
    )
    val scale = if (state is VpnState.Connecting) pulseScale else 1f

    val glowAlpha = if (state is VpnState.Connected) 0.4f else 0f

    Box(
        contentAlignment = Alignment.Center,
        modifier = modifier
            .size(100.dp)
            .graphicsLayer { scaleX = scale; scaleY = scale }
            .shadow(
                elevation = if (state is VpnState.Connected) 24.dp else 8.dp,
                shape = CircleShape,
                ambientColor = animatedColor.copy(alpha = glowAlpha),
                spotColor = animatedColor.copy(alpha = glowAlpha),
            )
            .clip(CircleShape)
            .background(
                brush = Brush.radialGradient(
                    colors = listOf(
                        animatedColor,
                        animatedColor.copy(alpha = 0.7f),
                    ),
                ),
            )
            .clickable(onClick = onClick),
    ) {
        Icon(
            imageVector = when (state) {
                is VpnState.Connected -> Icons.Filled.Security
                is VpnState.Error     -> Icons.Filled.Warning
                else                  -> Icons.Outlined.Security
            },
            contentDescription = null,
            tint = Color.White,
            modifier = Modifier.size(48.dp),
        )
    }
}
