package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C

/**
 * Stream multiplex bar chart. `heights` values 0..1, length = number of bars.
 *
 * `liveCount` is how many streams are actually up (streams_up). Bars at index
 * >= liveCount are dead streams and render in [deadColor] (danger) so a
 * Degraded tunnel honestly shows how many of N streams are down. When
 * liveCount >= heights.size every bar is live (the normal Healthy case).
 */
@Composable
fun MuxBars(
    heights: List<Float>,
    modifier: Modifier = Modifier,
    liveCount: Int = heights.size,
    deadColor: Color = C.danger,
) {
    val hairColor = C.hair
    val signalColor = C.signal
    val signalDimColor = C.signalDim
    Canvas(
        modifier
            .fillMaxWidth()
            .height(70.dp)
            .padding(horizontal = 14.dp, vertical = 14.dp),
    ) {
        val n = heights.size.coerceAtLeast(1)
        val gap = 4f
        val barW = (size.width - gap * (n - 1)) / n
        heights.forEachIndexed { i, hNorm ->
            val x = i * (barW + gap)
            // bottom hairline
            drawLine(
                hairColor,
                Offset(x, size.height),
                Offset(x + barW, size.height),
                strokeWidth = 1f,
            )
            val isDead = i >= liveCount
            // Dead streams: render a short flat-red stub so they're visible
            // as "present but down" rather than empty space.
            val fillH = if (isDead) {
                0.12f * size.height
            } else {
                (hNorm.coerceIn(0f, 1f)) * size.height
            }
            val top = size.height - fillH
            if (isDead) {
                drawRect(
                    color = deadColor,
                    topLeft = Offset(x, top),
                    size = Size(barW, fillH),
                )
            } else {
                drawRect(
                    brush = Brush.verticalGradient(listOf(signalColor, signalDimColor)),
                    topLeft = Offset(x, top),
                    size = Size(barW, fillH),
                )
            }
        }
    }
}
