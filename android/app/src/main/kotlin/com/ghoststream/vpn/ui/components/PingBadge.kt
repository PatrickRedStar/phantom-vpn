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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.ConnectingBlue
import com.ghoststream.vpn.ui.theme.PingGood
import com.ghoststream.vpn.ui.theme.PingHigh
import com.ghoststream.vpn.ui.theme.PingMid

@Composable
fun PingBadge(
    latencyMs: Long?,
    isPinging: Boolean,
    modifier: Modifier = Modifier,
) {
    val inf = rememberInfiniteTransition(label = "ping")
    val dotScale by inf.animateFloat(
        0.9f, 1.35f,
        infiniteRepeatable(tween(900, easing = EaseInOut), RepeatMode.Reverse),
        label = "dot_scale",
    )

    val (color, text) = when {
        isPinging -> ConnectingBlue to "..."
        latencyMs == null -> return
        latencyMs < 100   -> PingGood to "$latencyMs ms"
        latencyMs < 300   -> PingMid to "$latencyMs ms"
        else              -> PingHigh to "$latencyMs ms"
    }

    Row(
        modifier = modifier
            .clip(RoundedCornerShape(999.dp))
            .background(color.copy(alpha = 0.12f))
            .border(1.dp, color.copy(alpha = 0.28f), RoundedCornerShape(999.dp))
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(7.dp)
                .graphicsLayer {
                    if (isPinging) {
                        scaleX = dotScale; scaleY = dotScale
                    }
                }
                .clip(CircleShape)
                .background(color),
        )
        Text(
            text = text,
            fontFamily = FontFamily.Monospace,
            fontSize = 10.sp,
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}
