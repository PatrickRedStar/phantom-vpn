package com.ghoststream.vpn.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText

/** Rectangular chip — mono caps text + hairline border. Active = solid lime on warm-black. */
@Composable
fun GhostChip(
    text: String,
    active: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    accent: Color? = null, // override text colour when not active (e.g. warn for Warn chip)
) {
    val bg = if (active) C.signal else Color.Transparent
    val border = if (active) C.signal else C.hairBold
    val fg = when {
        active -> C.bg
        accent != null -> accent
        else -> C.textFaint
    }
    Box(
        modifier
            .clickable(onClick = onClick)
            .background(bg)
            .border(1.dp, border)
            .padding(horizontal = 10.dp, vertical = 5.dp),
    ) {
        Text(
            text = text.uppercase(),
            color = fg,
            style = com.ghoststream.vpn.ui.theme.GsText.chipText,
        )
    }
}

/** Lime-solid primary button spanning full width (used as Connect/Disconnect FAB). */
@Composable
fun GhostFab(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    outline: Boolean = false,
) {
    val signalColor = C.signal
    val bgColor = C.bg
    val bg = if (outline) Color.Transparent else signalColor
    val fg = if (outline) signalColor else bgColor
    Box(
        modifier
            .fillMaxWidth()
            .height(48.dp)
            .clickable(onClick = onClick)
            .background(bg)
            .then(if (outline) Modifier.border(1.dp, signalColor) else Modifier)
            .drawBehind {
                if (!outline) {
                    // soft glow
                    drawRect(
                        color = signalColor.copy(alpha = 0.2f),
                        topLeft = Offset(-6f, -6f),
                        size = androidx.compose.ui.geometry.Size(size.width + 12f, size.height + 12f),
                    )
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = text.uppercase(),
            color = fg,
            style = com.ghoststream.vpn.ui.theme.GsText.fabText,
        )
    }
}

/** Custom pill toggle switch in Ghoststream aesthetic. */
@Composable
fun GhostToggle(
    checked: Boolean,
    onToggle: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val signalC = C.signal
    val signalDimC = C.signalDim
    val textDimC = C.textDim
    val hairBoldC = C.hairBold
    val trackColor by animateColorAsState(
        if (checked) signalDimC.copy(alpha = 0.4f) else Color.Transparent,
        label = "toggle_track",
    )
    val knobColor by animateColorAsState(
        if (checked) signalC else textDimC,
        label = "toggle_knob",
    )
    Box(
        modifier
            .size(width = 34.dp, height = 18.dp)
            .clickable(onClick = onToggle)
            .border(1.dp, if (checked) signalC else hairBoldC)
            .background(trackColor)
            .padding(2.dp),
    ) {
        Box(
            Modifier
                .align(if (checked) Alignment.CenterEnd else Alignment.CenterStart)
                .size(12.dp)
                .background(knobColor)
                .drawBehind {
                    if (checked) {
                        // glow
                        drawRect(
                            color = signalC.copy(alpha = 0.4f),
                            topLeft = Offset(-3f, -3f),
                            size = androidx.compose.ui.geometry.Size(size.width + 6f, size.height + 6f),
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
            .border(1.dp, C.hairBold)
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
                modifier = Modifier.clickable { onSelect(value) },
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
            .border(1.dp, C.hairBold)
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
                modifier = Modifier.clickable { onSelect(code) },
            )
            if (idx < entries.size - 1) {
                Text("·", color = C.textFaint, style = com.ghoststream.vpn.ui.theme.GsText.valueMono)
            }
        }
    }
}
