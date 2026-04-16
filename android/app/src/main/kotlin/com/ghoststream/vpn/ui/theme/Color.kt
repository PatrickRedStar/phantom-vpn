package com.ghoststream.vpn.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.graphics.Color

// ── Ghoststream palette (warm-black + phosphor-lime) ────────────────────────
val GsBg        = Color(0xFF0A0908) // warm near-black
val GsBgElev    = Color(0xFF12110E)
val GsBgElev2   = Color(0xFF17150F)
val GsHair      = Color(0xFF2A2619) // hairline bordюр
val GsHairBold  = Color(0xFF3D3828)
val GsBone      = Color(0xFFE8E2D0) // bone / primary text
val GsTextDim   = Color(0xFF948A6F)
val GsTextFaint = Color(0xFF5A5240)
val GsSignal    = Color(0xFFC4FF3E) // phosphor lime
val GsSignalDim = Color(0xFF4A6010)
val GsWarn      = Color(0xFFFF7A3D) // cathode orange
val GsDanger    = Color(0xFFFF4A3D)

// Named aliases used in code
val GreenConnected = GsSignal
val RedError       = GsDanger
val YellowWarning  = GsWarn
val BlueDebug      = Color(0xFF6C8BA8) // DEBUG log rows

// ── Light "Daylight" palette (paper + ink + moss-green) ────────────────────
val GsLightBg        = Color(0xFFF1ECDC) // warm paper
val GsLightBgElev    = Color(0xFFE8E2D0) // card surface
val GsLightBgElev2   = Color(0xFFDDD6C2)
val GsLightHair      = Color(0xFFCBC3AD)
val GsLightHairBold  = Color(0xFFB5AD96)
val GsLightInk       = Color(0xFF16130C) // ink — primary text
val GsLightTextDim   = Color(0xFF5A5240)
val GsLightTextFaint = Color(0xFF948A6F)
val GsLightSignal    = Color(0xFF4A6010) // moss green accent
val GsLightSignalDim = Color(0xFF7A9B30)
val GsLightWarn      = Color(0xFFD4600A)
val GsLightDanger    = Color(0xFFCC3322)

// ── Theme-aware color provider ──────────────────────────────────────────────
data class GsColorSet(
    val bg: Color,
    val bgElev: Color,
    val bgElev2: Color,
    val hair: Color,
    val hairBold: Color,
    val bone: Color,
    val textDim: Color,
    val textFaint: Color,
    val signal: Color,
    val signalDim: Color,
    val warn: Color,
    val danger: Color,
)

val GsDarkColors = GsColorSet(
    bg = GsBg, bgElev = GsBgElev, bgElev2 = GsBgElev2,
    hair = GsHair, hairBold = GsHairBold, bone = GsBone,
    textDim = GsTextDim, textFaint = GsTextFaint,
    signal = GsSignal, signalDim = GsSignalDim,
    warn = GsWarn, danger = GsDanger,
)

val GsLightColors = GsColorSet(
    bg = GsLightBg, bgElev = GsLightBgElev, bgElev2 = GsLightBgElev2,
    hair = GsLightHair, hairBold = GsLightHairBold, bone = GsLightInk,
    textDim = GsLightTextDim, textFaint = GsLightTextFaint,
    signal = GsLightSignal, signalDim = GsLightSignalDim,
    warn = GsLightWarn, danger = GsLightDanger,
)

val LocalGsColors = compositionLocalOf { GsDarkColors }

/** Shorthand: `C.bg`, `C.signal` etc. — auto-switches dark/light. */
object C {
    val bg: Color @Composable get() = LocalGsColors.current.bg
    val bgElev: Color @Composable get() = LocalGsColors.current.bgElev
    val bgElev2: Color @Composable get() = LocalGsColors.current.bgElev2
    val hair: Color @Composable get() = LocalGsColors.current.hair
    val hairBold: Color @Composable get() = LocalGsColors.current.hairBold
    val bone: Color @Composable get() = LocalGsColors.current.bone
    val textDim: Color @Composable get() = LocalGsColors.current.textDim
    val textFaint: Color @Composable get() = LocalGsColors.current.textFaint
    val signal: Color @Composable get() = LocalGsColors.current.signal
    val signalDim: Color @Composable get() = LocalGsColors.current.signalDim
    val warn: Color @Composable get() = LocalGsColors.current.warn
    val danger: Color @Composable get() = LocalGsColors.current.danger
}
