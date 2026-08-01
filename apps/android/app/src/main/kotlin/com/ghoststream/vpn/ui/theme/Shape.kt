package com.ghoststream.vpn.ui.theme

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.unit.dp

// ── Shape scale (ADR 0015: One UI 8.5 / M3 Expressive) ──────────────────────
// Карточки — большой радиус, всё интерактивное — pill. Единый gutter 20 dp.

val GsShapeCard = RoundedCornerShape(26.dp)   // карточки и «острова»
val GsShapeInner = RoundedCornerShape(18.dp)  // вложенные карточки (профиль в drawer, клиенты)
val GsShapePill = RoundedCornerShape(999.dp)  // чипы, кнопки, nav-элементы
val GsShapeField = RoundedCornerShape(14.dp)  // текстовые поля

// Spring-кривая входа с overshoot — аналог cubic-bezier(.34,1.56,.64,1)
fun <T> gsSpring() = spring<T>(
    dampingRatio = 0.6f,
    stiffness = Spring.StiffnessMediumLow,
)
