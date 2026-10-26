package com.ghoststream.vpn.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import com.ghoststream.vpn.ui.theme.LocalIsDark

/**
 * Дышащая фосфорная аура (ADR 0015) — ambient-фон за контентом экрана.
 * Радиальный градиент от верхнего центра, 7-секундный цикл дыхания.
 * Цвет — от состояния туннеля (лайм / warn / danger / приглушённый).
 *
 * Реализован как Modifier, чтобы вешаться на корневой Column экрана без
 * дополнительной вложенности. Только dark-тема: на светлой бумаге свечение
 * выглядит грязью, там аура выключена.
 */
@Composable
fun Modifier.phosphorAura(color: Color, animate: Boolean): Modifier {
    val isDark = LocalIsDark.current
    if (!isDark) return this

    // Дышит только при живом туннеле: в покое вечный цикл гонял кадры впустую.
    val breathe = if (animate) {
        rememberInfiniteTransition(label = "aura").animateFloat(
            initialValue = 0.65f,
            targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(3500), RepeatMode.Reverse),
            label = "breathe",
        )
    } else null
    // Плавная смена цвета при смене состояния (Connected → Reconnecting и т.п.)
    val animatedColor by animateColorAsState(color, tween(900), label = "aura_color")

    return drawBehind {
        val radius = size.width * 0.85f
        val b = breathe?.value ?: 1f
        drawCircle(
            brush = Brush.radialGradient(
                colors = listOf(
                    animatedColor.copy(alpha = 0.075f * b),
                    animatedColor.copy(alpha = 0.028f * b),
                    Color.Transparent,
                ),
                center = Offset(size.width / 2f, -size.width * 0.25f),
                radius = radius,
            ),
            center = Offset(size.width / 2f, -size.width * 0.25f),
            radius = radius,
        )
    }
}
