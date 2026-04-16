package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C

/** Pulsing lime dot (≈1.6s cycle). */
@Composable
fun PulseDot(
    modifier: Modifier = Modifier,
    color: Color = C.signal,
    size: Dp = 5.dp,
) {
    val transition = rememberInfiniteTransition(label = "pulse_dot")
    val alpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0.25f,
        animationSpec = infiniteRepeatable(tween(1600), RepeatMode.Reverse),
        label = "alpha",
    )
    Canvas(modifier = modifier.size(size)) {
        // Soft glow
        drawCircle(color = color.copy(alpha = alpha * 0.4f), radius = this.size.minDimension)
        drawCircle(color = color.copy(alpha = alpha), radius = this.size.minDimension / 2)
    }
}
