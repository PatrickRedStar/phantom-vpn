package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsHair

/** Draws a 1-px hairline along the bottom edge of the composable. */
fun Modifier.hairlineBottom(color: Color = GsHair): Modifier = drawBehind {
    val y = size.height - 0.5f
    drawLine(color, Offset(0f, y), Offset(size.width, y), strokeWidth = 1f)
}

fun Modifier.hairlineTop(color: Color = GsHair): Modifier = drawBehind {
    drawLine(color, Offset(0f, 0.5f), Offset(size.width, 0.5f), strokeWidth = 1f)
}

fun Modifier.hairlineEnd(color: Color = GsHair): Modifier = drawBehind {
    val x = size.width - 0.5f
    drawLine(color, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1f)
}

/** Full-width dashed hairline separator. */
@Composable
fun DashedHairline(
    modifier: Modifier = Modifier,
    color: Color = C.hair,
    height: Dp = 1.dp,
) {
    Canvas(modifier.fillMaxWidth().height(height)) {
        drawLine(
            color = color,
            start = Offset(0f, size.height / 2),
            end = Offset(size.width, size.height / 2),
            strokeWidth = 1f,
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(4f, 4f), 0f),
        )
    }
}

/** Solid hairline separator. */
@Composable
fun SolidHairline(
    modifier: Modifier = Modifier,
    color: Color = C.hair,
) {
    Box(modifier.fillMaxWidth().height(1.dp).drawBehind {
        drawLine(color, Offset(0f, size.height / 2), Offset(size.width, size.height / 2), strokeWidth = size.height)
    })
}
