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
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C

/** 8-lane stream multiplex bar chart. `heights` values 0..1, length = number of bars. */
@Composable
fun MuxBars(
    heights: List<Float>,
    modifier: Modifier = Modifier,
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
            val fillH = (hNorm.coerceIn(0f, 1f)) * size.height
            val top = size.height - fillH
            // glow
            drawRect(
                brush = Brush.verticalGradient(listOf(signalColor, signalDimColor)),
                topLeft = Offset(x, top),
                size = Size(barW, fillH),
            )
        }
    }
}
