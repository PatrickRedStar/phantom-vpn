package com.ghoststream.vpn.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText

/** Pill-chip (ADR 0015). Active = solid lime pill, idle = едва заметная tonal-плашка. */
@Composable
fun GhostChip(
    text: String,
    active: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    accent: Color? = null, // override text colour when not active (e.g. warn for Warn chip)
) {
    val bg = if (active) C.signal else C.bone.copy(alpha = 0.045f)
    val fg = when {
        active -> C.bg
        accent != null -> accent
        else -> C.textDim
    }
    Box(
        modifier
            .clip(com.ghoststream.vpn.ui.theme.GsShapePill)
            .clickable(onClick = onClick)
            .background(bg)
            .padding(horizontal = 14.dp, vertical = 10.dp),
    ) {
        Text(
            text = text.uppercase(),
            color = fg,
            style = com.ghoststream.vpn.ui.theme.GsText.chipText,
        )
    }
}

/**
 * Lime-solid primary button spanning full width (used as Connect/Disconnect FAB).
 *
 * `contentDescription` is accepted explicitly so TalkBack can read a
 * different label than the visible text (e.g. "Disconnect from
 * Ghoststream" instead of "DISCONNECT"). When null, the visible text
 * is used — fine for short imperative labels.
 */
@Composable
fun GhostFab(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    outline: Boolean = false,
    enabled: Boolean = true,
    contentDescription: String? = null,
    glow: Boolean = true, // false для кнопок внутри диалогов/списков
) {
    val haptic = LocalHapticFeedback.current
    val signalColor = C.signal
    val bgColor = C.bg
    // ADR 0015: pill 56 dp. outline=true → tonal-pill (лайм 11 % + рамка 30 %),
    // outline=false → filled lime. Glow пульсирует только у tonal (attract state
    // «подключено»); filled и так самая яркая вещь на экране.
    val a11yLabel = contentDescription ?: text
    // v0.27.0: dim while disabled so the user can see the button is in a
    // transitional state ("Отключение...") and not just visually identical to
    // the active form. Click is consumed by clickable(enabled=false) below.
    val alpha = if (enabled) 1f else 0.45f
    // Медленная пульсация свечения (4.4 s) — только у живой tonal-кнопки;
    // у остальных свечение статичное и бесконечный переход не крутится.
    // Значение читается в graphicsLayer: кадр анимации перерисовывает слой,
    // а не рекомпозирует кнопку.
    val glowElevPx: State<Float> = if (enabled && glow && outline) {
        rememberInfiniteTransition(label = "fab_glow").animateFloat(
            initialValue = 5f,
            targetValue = 12f,
            animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                tween(2200),
                androidx.compose.animation.core.RepeatMode.Reverse,
            ),
            label = "glow",
        )
    } else {
        remember(enabled, glow) { mutableFloatStateOf(if (enabled && glow) 8f else 0f) }
    }
    // M3E shape-morph: пружинное сжатие при нажатии
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val pressScale by animateFloatAsState(
        targetValue = if (pressed) 0.97f else 1f,
        animationSpec = com.ghoststream.vpn.ui.theme.gsSpring(),
        label = "press",
    )
    val shape = com.ghoststream.vpn.ui.theme.GsShapePill
    Box(
        modifier
            .fillMaxWidth()
            .height(56.dp)
            .scale(pressScale)
            .alpha(alpha)
            // Свечение — тень слоя с лаймовым ambient: идёт строго по форме pill
            // и не может «уехать». Ручной drawRoundRect давал полосы по краям
            // (сдвиг -4dp / +4dp) — см. баг-репорт 2026-08-01.
            .graphicsLayer {
                shadowElevation = glowElevPx.value.dp.toPx()
                this.shape = shape
                clip = false
                ambientShadowColor = signalColor
                spotShadowColor = Color.Transparent // spot направленная → ореол «уезжал»
            }
            .clip(shape)
            .clickable(
                interactionSource = interaction,
                indication = null,
                enabled = enabled,
            ) {
                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                onClick()
            }
            .semantics {
                role = Role.Button
                this.contentDescription = a11yLabel
            }
            .background(if (outline) signalColor.copy(alpha = 0.11f) else signalColor)
            .then(
                if (outline) Modifier.border(1.dp, signalColor.copy(alpha = 0.30f), shape)
                else Modifier,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text.uppercase(),
            color = if (outline) signalColor else bgColor,
            style = com.ghoststream.vpn.ui.theme.GsText.fabText,
        )
    }
}

/** Pill toggle switch (ADR 0015) — круглая шайба, spring-скольжение, glow при ON. */
@Composable
fun GhostToggle(
    checked: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val haptic = LocalHapticFeedback.current
    val signalC = C.signal
    val signalDimC = C.signalDim
    val textDimC = C.textDim
    val hairBoldC = C.hairBold
    val pill = com.ghoststream.vpn.ui.theme.GsShapePill
    val trackColor by animateColorAsState(
        if (checked) signalDimC.copy(alpha = 0.4f) else Color.Transparent,
        label = "toggle_track",
    )
    val knobColor by animateColorAsState(
        if (checked) signalC else textDimC,
        label = "toggle_knob",
    )
    // TalkBack читает это как переключатель; зона касания — не меньше 48 dp,
    // рисуется по-прежнему 44×24.
    Box(
        modifier
            .minimumInteractiveComponentSize()
            .toggleable(
                value = checked,
                interactionSource = null,
                indication = null,
                role = Role.Switch,
                onValueChange = { haptic.performHapticFeedback(HapticFeedbackType.LongPress); onToggle() },
            )
            .wrapContentSize(Alignment.Center)
            .size(width = 44.dp, height = 24.dp)
            .clip(pill)
            .border(1.dp, if (checked) signalC else hairBoldC, pill)
            .background(trackColor)
            .padding(3.dp),
    ) {
        Box(
            Modifier
                .align(if (checked) Alignment.CenterEnd else Alignment.CenterStart)
                .size(16.dp)
                .clip(androidx.compose.foundation.shape.CircleShape)
                .background(knobColor)
                .drawBehind {
                    if (checked) {
                        // glow-ореол вокруг шайбы
                        drawCircle(
                            color = signalC.copy(alpha = 0.4f),
                            radius = size.minDimension * 0.9f,
                        )
                    }
                },
        )
    }
}

/** DARK · LIGHT · SYS theme switch. */
@Composable
fun ThemeSwitch(
    selected: String, // "dark" | "light" | "system"
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .border(1.dp, C.hairBold, com.ghoststream.vpn.ui.theme.GsShapePill)
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val entries = listOf("dark" to "DRK", "light" to "LHT", "system" to "SYS")
        entries.forEachIndexed { idx, (value, label) ->
            val active = selected == value
            Text(
                text = label,
                color = if (active) C.signal else C.textFaint,
                style = com.ghoststream.vpn.ui.theme.GsText.valueMono,
                modifier = Modifier.clickable { onSelect(value) }.padding(horizontal = 8.dp, vertical = 8.dp),
            )
            if (idx < entries.size - 1) {
                Text("·", color = C.textFaint, style = com.ghoststream.vpn.ui.theme.GsText.valueMono)
            }
        }
    }
}

/** RU · EN language switch. null = system. */
@Composable
fun LangSwitch(
    selected: String?, // "ru" | "en" | null (system)
    onSelect: (String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .border(1.dp, C.hairBold, com.ghoststream.vpn.ui.theme.GsShapePill)
            .padding(horizontal = 10.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val entries: List<Pair<String?, String>> = listOf("ru" to "RU", "en" to "EN", null to "SYS")
        entries.forEachIndexed { idx, (code, label) ->
            val active = selected == code
            Text(
                text = label,
                color = if (active) C.signal else C.textFaint,
                style = com.ghoststream.vpn.ui.theme.GsText.valueMono,
                modifier = Modifier.clickable { onSelect(code) }.padding(horizontal = 8.dp, vertical = 8.dp),
            )
            if (idx < entries.size - 1) {
                Text("·", color = C.textFaint, style = com.ghoststream.vpn.ui.theme.GsText.valueMono)
            }
        }
    }
}
