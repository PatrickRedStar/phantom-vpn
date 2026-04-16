package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C

/** Plain hairline-bordered card, warm-black elevated. */
@Composable
fun GhostCard(
    modifier: Modifier = Modifier,
    bg: Color = C.bgElev,
    border: Color = C.hair,
    active: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val signalColor = C.signal
    val signalDimColor = C.signalDim
    Box(
        modifier
            .background(
                if (active)
                    Brush.horizontalGradient(
                        0f to signalColor.copy(alpha = 0.04f),
                        0.7f to Color.Transparent,
                    )
                else Brush.linearGradient(listOf(bg, bg)),
            )
            .border(1.dp, border)
            .drawBehind {
                if (active) {
                    // lime vertical strip on the left edge with glow
                    val y0 = size.height * 0.18f
                    val y1 = size.height * 0.82f
                    drawLine(
                        signalDimColor,
                        Offset(0.5f, y0),
                        Offset(0.5f, y1),
                        strokeWidth = 6f,
                    )
                    drawLine(
                        signalColor,
                        Offset(0.5f, y0),
                        Offset(0.5f, y1),
                        strokeWidth = 2f,
                    )
                }
            },
    ) {
        Column {
            content()
        }
    }
}

/** A dashed-bordered card used for "add profile" CTA. */
@Composable
fun DashedGhostCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val bgElevColor = C.bgElev
    val hairColor = C.hair
    Column(
        modifier
            .background(bgElevColor)
            .drawBehind {
                // dashed rectangle
                val stroke = 1f
                val dashOn = 4f
                val dashOff = 4f
                val w = size.width
                val h = size.height
                fun drawDashedLine(from: Offset, to: Offset) {
                    val dx = to.x - from.x
                    val dy = to.y - from.y
                    val len = kotlin.math.sqrt(dx * dx + dy * dy)
                    val nx = dx / len
                    val ny = dy / len
                    var travelled = 0f
                    while (travelled < len) {
                        val segEnd = (travelled + dashOn).coerceAtMost(len)
                        drawLine(
                            hairColor,
                            Offset(from.x + nx * travelled, from.y + ny * travelled),
                            Offset(from.x + nx * segEnd, from.y + ny * segEnd),
                            strokeWidth = stroke,
                        )
                        travelled = segEnd + dashOff
                    }
                }
                drawDashedLine(Offset(0f, 0.5f), Offset(w, 0.5f))
                drawDashedLine(Offset(0f, h - 0.5f), Offset(w, h - 0.5f))
                drawDashedLine(Offset(0.5f, 0f), Offset(0.5f, h))
                drawDashedLine(Offset(w - 0.5f, 0f), Offset(w - 0.5f, h))
            },
    ) {
        content()
    }
}
