package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.EaseInOut
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.ui.theme.ConnectingBlue
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.RedError

@Composable
fun ConnectionPill(vpnState: VpnState, modifier: Modifier = Modifier) {
    val inf = rememberInfiniteTransition(label = "pill")

    // Connected: dot pulse (alpha)
    val dotAlpha by inf.animateFloat(
        0.42f, 1f,
        infiniteRepeatable(tween(1800, easing = EaseInOut), RepeatMode.Reverse),
        label = "dot_alpha",
    )
    // Connecting: dot scale + opacity
    val connectDotScale by inf.animateFloat(
        0.9f, 1.35f,
        infiniteRepeatable(tween(900, easing = EaseInOut), RepeatMode.Reverse),
        label = "dot_scale",
    )
    val connectDotAlpha by inf.animateFloat(
        0.55f, 1f,
        infiniteRepeatable(tween(900, easing = EaseInOut), RepeatMode.Reverse),
        label = "dot_connect_alpha",
    )

    val (bgColor, dotColor, text) = when (vpnState) {
        is VpnState.Connected    -> Triple(GreenConnected.copy(.12f), GreenConnected, "Подключён")
        is VpnState.Connecting   -> Triple(ConnectingBlue.copy(.12f), ConnectingBlue, "Подключение...")
        is VpnState.Error        -> Triple(RedError.copy(.12f), RedError, "Ошибка")
        is VpnState.Disconnecting -> Triple(Color.White.copy(.06f), Color.White.copy(.52f), "Отключение...")
        else                     -> Triple(Color.White.copy(.06f), Color.White.copy(.52f), "Отключён")
    }

    Row(
        modifier = modifier
            .clip(RoundedCornerShape(20.dp))
            .background(bgColor)
            .border(0.5.dp, dotColor.copy(.28f), RoundedCornerShape(20.dp))
            .padding(horizontal = 14.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(6.dp)
                .graphicsLayer {
                    when (vpnState) {
                        is VpnState.Connected -> {
                            alpha = dotAlpha
                        }
                        is VpnState.Connecting -> {
                            scaleX = connectDotScale
                            scaleY = connectDotScale
                            alpha = connectDotAlpha
                        }
                        else -> {}
                    }
                }
                .clip(CircleShape)
                .background(dotColor),
        )
        Text(
            text = text,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            letterSpacing = 0.4.sp,
            color = dotColor,
        )
    }
}
