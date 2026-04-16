package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C

/** RX/TX oscilloscope trace. Samples are normalized within this call — caller
 *  passes up to N=60 samples, bigger = higher line. */
@Composable
fun ScopeChart(
    rxSamples: List<Float>,
    txSamples: List<Float>,
    modifier: Modifier = Modifier,
) {
    val hairColor = C.hair
    val signalColor = C.signal
    val warnColor = C.warn
    Canvas(modifier.fillMaxWidth().height(90.dp)) {
        val w = size.width
        val h = size.height
        // Grid lines (3 horizontal)
        for (i in 1..3) {
            val y = h * i / 4f
            drawLine(hairColor, Offset(0f, y), Offset(w, y), strokeWidth = 0.5f)
        }

        fun tracePath(samples: List<Float>, ceil: Float): Path {
            val p = Path()
            if (samples.isEmpty()) return p
            val n = samples.size.coerceAtLeast(2)
            val step = w / (n - 1).coerceAtLeast(1).toFloat()
            samples.forEachIndexed { i, v ->
                val norm = (v / ceil.coerceAtLeast(1f)).coerceIn(0f, 1f)
                val y = h - norm * (h * 0.85f) - h * 0.05f
                val x = i * step
                if (i == 0) p.moveTo(x, y) else p.lineTo(x, y)
            }
            return p
        }

        val rxMax = (rxSamples.maxOrNull() ?: 0f).coerceAtLeast(1f)
        val txMax = (txSamples.maxOrNull() ?: 0f).coerceAtLeast(1f)
        val ceil = maxOf(rxMax, txMax, 1f)

        if (rxSamples.isNotEmpty()) {
            val path = tracePath(rxSamples, ceil)
            // soft glow
            drawPath(path, signalColor.copy(alpha = 0.3f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 5f))
            drawPath(path, signalColor, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1.5f))
            // fill under
            val fill = Path().apply {
                addPath(path)
                lineTo(w, h); lineTo(0f, h); close()
            }
            drawPath(fill, Brush.verticalGradient(listOf(signalColor.copy(alpha = 0.2f), Color.Transparent)))
        }
        if (txSamples.isNotEmpty()) {
            val path = tracePath(txSamples, ceil)
            drawPath(path, warnColor.copy(alpha = 0.25f), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 4f))
            drawPath(path, warnColor, style = androidx.compose.ui.graphics.drawscope.Stroke(width = 1f))
        }
    }
}
