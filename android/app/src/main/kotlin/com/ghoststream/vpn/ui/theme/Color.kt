package com.ghoststream.vpn.ui.theme

import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

// ── Dark palette (default) ──────────────────────────────────────────────────

val PageBase           = Color(0xFF090B16)
val DarkBackground     = Color(0xFF0D0D1C)
val DarkSurface        = Color(0xFF13132A)
val DarkSurfaceVariant = Color(0xFF1E1F3A)

val AccentPurple      = Color(0xFF7C6AF7)
val AccentPurpleLight = Color(0xFFAE9BFF)
val AccentTeal        = Color(0xFF22D3A0)
val AccentIndigo      = Color(0xFF536DFE)

val TextPrimary   = Color(0xFFF0EFFF)
val TextSecondary = Color(0x99F0EFFF)   // ~60%
val TextTertiary  = Color(0x59F0EFFF)   // ~35%

val CardBg     = Color(0x0DFFFFFF)       // 5%  white
val CardBorder = Color(0x17FFFFFF)       // 9%  white

val GreenConnected = Color(0xFF22D3A0)
val RedError       = Color(0xFFFF5252)
val YellowWarning  = Color(0xFFFFD740)
val BlueDebug      = Color(0xFF60A5FA)

val StatDlColor = Color(0xFF06B6D4)   // cyan   — Download
val StatUlColor = Color(0xFF8B5CF6)   // violet — Upload
val StatSeColor = Color(0xFFFB923C)   // orange — Session
val StatPkColor = Color(0xFF22D3A0)   // teal   — Packets

// ── Page glow gradients ─────────────────────────────────────────────────────
val PageGlowPurple = Color(0x387C6AF7)  // ~22% opacity
val PageGlowTeal   = Color(0x1F22D3A0)  // ~12% opacity

// ── Ping badge ──────────────────────────────────────────────────────────────
val PingGood = Color(0xFF34D399)
val PingMid  = Color(0xFFFBBF24)
val PingHigh = Color(0xFFFB7185)

// ── Overlay sheet gradients (dark) ──────────────────────────────────────────
val SheetGradStart     = Color(0xF01E1F3A)  // settings default
val SheetGradEnd       = Color(0xEB101122)
val LogsSheetStart     = Color(0xF2141E34)
val LogsSheetEnd       = Color(0xEB0C101E)
val SettSheetStart     = Color(0xF21C1534)
val SettSheetEnd       = Color(0xEB0F0E1F)
val AdminSheetStart    = Color(0xF2191B2C)
val AdminSheetEnd      = Color(0xEB11121F)
val DnsSheetStart      = Color(0xF8122326)
val DnsSheetEnd        = Color(0xF50A1218)
val AppsSheetStart     = Color(0xF816142D)
val AppsSheetEnd       = Color(0xF50B0D1C)
val RoutesSheetStart   = Color(0xF818152E)
val RoutesSheetEnd     = Color(0xF50B0E1D)
val AddServerSheetStart = Color(0xFA1C1836)
val AddServerSheetEnd   = Color(0xF50E101F)

// ── Admin hero ──────────────────────────────────────────────────────────────
val AdminHeroGradStart = Color(0x387C6AF7)
val AdminHeroGradMid   = Color(0xF51A1C34)
val AdminHeroGradEnd   = Color(0xFA0B0F1C)

// ── Misc semantic ───────────────────────────────────────────────────────────
val OverlayBackdrop  = Color(0x6B050412)
val MiniToastBg      = Color(0xF0121322)
val ConnectingBlue   = Color(0xFF60A5FA)
val DangerRose       = Color(0xFFFB7185)

// ═══════════════════════════════════════════════════════════════════════════
// GhostColors — custom semantic color system (dark + light)
// ═══════════════════════════════════════════════════════════════════════════

@Immutable
data class GhostColors(
    val pageBase: Color,
    val pageGlowA: Color,
    val pageGlowB: Color,
    val background: Color,
    val surface: Color,
    val cardBg: Color,
    val cardBorder: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val accent: Color,
    val accentTeal: Color,
    val overlayBackdrop: Color,
    val sheetGradStart: Color,
    val sheetGradEnd: Color,
    val logsSheetStart: Color,
    val logsSheetEnd: Color,
    val settSheetStart: Color,
    val settSheetEnd: Color,
    val adminSheetStart: Color,
    val adminSheetEnd: Color,
    val miniToastBg: Color,
    val shadowColor: Color,
)

val DarkGhostColors = GhostColors(
    pageBase        = PageBase,
    pageGlowA       = PageGlowPurple,
    pageGlowB       = PageGlowTeal,
    background      = DarkBackground,
    surface         = DarkSurface,
    cardBg          = CardBg,
    cardBorder      = CardBorder,
    textPrimary     = TextPrimary,
    textSecondary   = TextSecondary,
    textTertiary    = TextTertiary,
    accent          = AccentPurple,
    accentTeal      = AccentTeal,
    overlayBackdrop = OverlayBackdrop,
    sheetGradStart  = SheetGradStart,
    sheetGradEnd    = SheetGradEnd,
    logsSheetStart  = LogsSheetStart,
    logsSheetEnd    = LogsSheetEnd,
    settSheetStart  = SettSheetStart,
    settSheetEnd    = SettSheetEnd,
    adminSheetStart = AdminSheetStart,
    adminSheetEnd   = AdminSheetEnd,
    miniToastBg     = MiniToastBg,
    shadowColor     = Color(0x6B000000),
)

val LightGhostColors = GhostColors(
    pageBase        = Color(0xFFEEF2FF),
    pageGlowA       = Color(0x296B57F6),
    pageGlowB       = Color(0x1C0F9F85),
    background      = Color(0xFFF7F8FF),
    surface         = Color(0xFFEDF0FF),
    cardBg          = Color(0x0D141824),
    cardBorder      = Color(0x1C141824),
    textPrimary     = Color(0xFF171B27),
    textSecondary   = Color(0xB8171B27),
    textTertiary    = Color(0x80171B27),
    accent          = Color(0xFF6B57F6),
    accentTeal      = Color(0xFF0F9F85),
    overlayBackdrop = Color(0x9EEFF3FF),
    sheetGradStart  = Color(0xF5FFFFFF),
    sheetGradEnd    = Color(0xEDF3F6FF),
    logsSheetStart  = Color(0xF8FFFFFF),
    logsSheetEnd    = Color(0xEBF1F5FF),
    settSheetStart  = Color(0xF8FFFFFF),
    settSheetEnd    = Color(0xEDF6F3FF),
    adminSheetStart = Color(0xF8FFFFFF),
    adminSheetEnd   = Color(0xEDF5F6FF),
    miniToastBg     = Color(0xF5FFFFFF),
    shadowColor     = Color(0x33759EAD),
)

val LocalGhostColors = staticCompositionLocalOf { DarkGhostColors }
