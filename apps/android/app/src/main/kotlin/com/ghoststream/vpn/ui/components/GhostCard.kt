package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsShapeCard
import com.ghoststream.vpn.ui.theme.GsShapeInner
import com.ghoststream.vpn.ui.theme.LocalIsDark

/**
 * Tonal card — ADR 0015. Большой радиус (26 dp), поверхность bgElev с едва
 * заметным top-light градиентом, рамка bone 5.5 % вместо жёсткого hairline.
 * `active` — лаймовое свечение по рамке (glow вместо тени, тени на тёплом
 * чёрном не читаются).
 */
@Composable
fun GhostCard(
    modifier: Modifier = Modifier,
    bg: Color = C.bgElev,
    border: Color = Color.Unspecified, // legacy-параметр; Unspecified = токен ADR 0015
    active: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val isDark = LocalIsDark.current
    val bone = C.bone
    val signal = C.signal
    // top-light 2.8 % работает только на тёмной поверхности; на бумаге — чистый цвет
    val topLight = if (isDark) bone.copy(alpha = 0.028f) else Color.Transparent
    val borderColor = when {
        active -> signal.copy(alpha = 0.35f)
        border != Color.Unspecified -> border
        isDark -> bone.copy(alpha = 0.055f)
        else -> C.hair
    }
    Box(
        modifier
            .clip(GsShapeCard)
            .background(
                Brush.verticalGradient(
                    0f to topLight.compositeOverIfDark(bg, isDark),
                    0.26f to bg,
                ),
            )
            .then(
                if (active)
                    Modifier.drawBehind {
                        // мягкое свечение внутрь от левого края — «активная» подсветка
                        drawRoundRect(
                            brush = Brush.horizontalGradient(
                                0f to signal.copy(alpha = 0.05f),
                                0.6f to Color.Transparent,
                            ),
                            cornerRadius = CornerRadius(26.dp.toPx()),
                        )
                    }
                else Modifier,
            )
            .border(1.dp, borderColor, GsShapeCard),
    ) {
        Column {
            content()
        }
    }
}

private fun Color.compositeOverIfDark(bg: Color, isDark: Boolean): Color =
    if (isDark) this.compositeOver(bg) else bg

private fun Color.compositeOver(bg: Color): Color {
    val a = alpha
    return Color(
        red = red * a + bg.red * (1 - a),
        green = green * a + bg.green * (1 - a),
        blue = blue * a + bg.blue * (1 - a),
        alpha = 1f,
    )
}

/** A dashed-bordered card used for "add profile" CTA — pill-скругление 18 dp. */
@Composable
fun DashedGhostCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val hairBold = C.hairBold
    Column(
        modifier
            .clip(GsShapeInner)
            .drawBehind {
                drawRoundRect(
                    color = hairBold,
                    cornerRadius = CornerRadius(18.dp.toPx()),
                    style = Stroke(
                        width = 1.5.dp.toPx(),
                        pathEffect = PathEffect.dashPathEffect(floatArrayOf(10f, 8f), 0f),
                    ),
                )
            },
    ) {
        content()
    }
}
