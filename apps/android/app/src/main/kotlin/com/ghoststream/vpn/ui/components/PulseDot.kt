package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.LinearEasing
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
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C

/**
 * Live status dot — ADR 0015: ping-кольцо расходится от точки (2.2 s цикл),
 * как у «живых» индикаторов One UI. Само ядро мягко пульсирует по альфе.
 */
@Composable
fun PulseDot(
    modifier: Modifier = Modifier,
    color: Color = C.signal,
    size: Dp = 5.dp,
) {
    val transition = rememberInfiniteTransition(label = "pulse_dot")
    val alpha by transition.animateFloat(
        initialValue = 1f,
        targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(1600), RepeatMode.Reverse),
        label = "alpha",
    )
    // ping: 0..1 → кольцо от 0.55R до 1.9R с затуханием
    val ping by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2200, easing = LinearEasing), RepeatMode.Restart),
        label = "ping",
    )
    Canvas(modifier = modifier.size(size)) {
        val r = this.size.minDimension / 2
        // расходящееся кольцо
        val ringR = r * (0.55f + 1.35f * ping)
        val ringA = (1f - ping) * 0.65f
        drawCircle(color = color.copy(alpha = ringA), radius = ringR, style = Stroke(width = 1.dp.toPx()))
        // мягкое свечение + ядро
        drawCircle(color = color.copy(alpha = alpha * 0.35f), radius = r * 1.6f)
        drawCircle(color = color.copy(alpha = alpha), radius = r)
    }
}
