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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.RedError

@Composable
fun ConnectionPill(vpnState: VpnState, modifier: Modifier = Modifier) {
    val infiniteTransition = rememberInfiniteTransition(label = "pill")
    val dotAlpha by infiniteTransition.animateFloat(
        initialValue = 0.35f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(700, easing = EaseInOut), RepeatMode.Reverse),
        label = "dot_alpha",
    )

    val (bgColor, dotColor, text, animateDot) = when (vpnState) {
        is VpnState.Connected    -> Quad(GreenConnected.copy(.14f), GreenConnected,                         "Подключён",       true)
        is VpnState.Connecting   -> Quad(BlueDebug.copy(.12f),      BlueDebug,                              "Подключение...",  true)
        is VpnState.Error        -> Quad(RedError.copy(.12f),        RedError,                               "Ошибка",          false)
        is VpnState.Disconnecting -> Quad(Color.White.copy(.06f),   Color.White.copy(.42f),                 "Отключение...",   false)
        else                     -> Quad(Color.White.copy(.06f),     Color.White.copy(.42f),                 "Отключён",        false)
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
                .clip(CircleShape)
                .background(dotColor.copy(alpha = if (animateDot) dotAlpha else 0.5f)),
        )
        Text(
            text = text,
            style = MaterialTheme.typography.labelMedium.copy(
                fontWeight = FontWeight.Medium,
                letterSpacing = 0.4.sp,
            ),
            color = dotColor,
        )
    }
}

private data class Quad<A, B, C, D>(val a: A, val b: B, val c: C, val d: D)
