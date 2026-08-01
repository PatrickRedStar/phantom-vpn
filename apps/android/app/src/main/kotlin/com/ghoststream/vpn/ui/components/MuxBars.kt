package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C

/**
 * Stream multiplex bar chart. `heights` values 0..1, length = number of bars.
 *
 * ADR 0015:
 *  - ширина полосы клампится 8..22 dp — на широких карточках полосы не
 *    расползаются в плашки, группа центрируется;
 *  - скруглённая шапка (6 dp сверху / 3 dp снизу);
 *  - живой пульс: полосы «дышат» (0.72..1 от высоты) с фазовым сдвигом по
 *    индексу — движение читается как трафик, а не синхронный метроном.
 *    Пульс — чисто визуальный слой поверх реальных высот из runtime.
 *
 * `liveCount` is how many streams are actually up (streams_up). Bars at index
 * >= liveCount are dead streams and render in [deadColor] (danger) so a
 * Degraded tunnel honestly shows how many of N streams are down.
 */
@Composable
fun MuxBars(
    heights: List<Float>,
    modifier: Modifier = Modifier,
    liveCount: Int = heights.size,
    deadColor: Color = C.danger,
    animate: Boolean = true, // false в standby — пульс без трафика был бы враньём
) {
    val hairColor = C.hair
    val signalColor = C.signal
    val signalDimColor = C.signalDim

    // Один бесконечный переход на всю группу; фаза каждой полосы — от индекса.
    val transition = rememberInfiniteTransition(label = "mux_pulse")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2600), RepeatMode.Restart),
        label = "phase",
    )

    Canvas(
        modifier
            .fillMaxWidth()
            .height(70.dp)
            .padding(horizontal = 14.dp, vertical = 14.dp),
    ) {
        val n = heights.size.coerceAtLeast(1)
        val gap = 7.dp.toPx()
        // Кламп ширины полосы: 8..22 dp; группа центрируется, если уперлись в кламп
        val rawW = (size.width - gap * (n - 1)) / n
        val barW = rawW.coerceIn(8.dp.toPx(), 22.dp.toPx())
        val groupW = barW * n + gap * (n - 1)
        val x0 = (size.width - groupW) / 2f
        val rTop = CornerRadius(6.dp.toPx())
        val rBot = CornerRadius(3.dp.toPx())

        heights.forEachIndexed { i, hNorm ->
            val x = x0 + i * (barW + gap)
            // bottom hairline под каждой полосой
            drawLine(
                hairColor,
                Offset(x, size.height),
                Offset(x + barW, size.height),
                strokeWidth = 1f,
            )
            val isDead = i >= liveCount
            // «дыхание»: 0.72..1 по синусу с фазой; мёртвые полосы не дышат
            val pulse = if (isDead || !animate) 1f else {
                val t = (phase + i * 0.37f) % 1f
                val s = (kotlin.math.sin(t * 2.0 * Math.PI).toFloat() + 1f) / 2f
                0.72f + 0.28f * s
            }
            val fillH = if (isDead) {
                0.12f * size.height
            } else {
                hNorm.coerceIn(0f, 1f) * size.height * pulse
            }
            val top = size.height - fillH
            val path = Path().apply {
                addRoundRect(
                    RoundRect(
                        left = x, top = top, right = x + barW, bottom = size.height,
                        topLeftCornerRadius = rTop,
                        topRightCornerRadius = rTop,
                        bottomLeftCornerRadius = rBot,
                        bottomRightCornerRadius = rBot,
                    ),
                )
            }
            if (isDead) {
                drawPath(path, deadColor)
            } else {
                drawPath(
                    path,
                    Brush.verticalGradient(
                        colors = listOf(signalColor, signalDimColor),
                        startY = top,
                        endY = size.height,
                    ),
                )
            }
        }
    }
}
