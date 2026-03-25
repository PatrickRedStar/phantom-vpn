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

val CardBg     = Color(0x0DFFFFFF)       // 5%  white — per HTML --card
val CardBorder = Color(0x17FFFFFF)       // 9%  white — per HTML --border

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

// ── Overlay sheet gradients — FULLY OPAQUE (no see-through) ─────────────────
val SheetGradStart     = Color(0xFF1E1F3A)
val SheetGradEnd       = Color(0xFF101122)
val LogsSheetStart     = Color(0xFF141E34)
val LogsSheetEnd       = Color(0xFF0C101E)
val SettSheetStart     = Color(0xFF1C1534)
val SettSheetEnd       = Color(0xFF0F0E1F)
val AdminSheetStart    = Color(0xFF191B2C)
val AdminSheetEnd      = Color(0xFF11121F)
val DnsSheetStart      = Color(0xFF122326)
val DnsSheetEnd        = Color(0xFF0A1218)
val AppsSheetStart     = Color(0xFF16142D)
val AppsSheetEnd       = Color(0xFF0B0D1C)
val RoutesSheetStart   = Color(0xFF18152E)
val RoutesSheetEnd     = Color(0xFF0B0E1D)
val AddServerSheetStart = Color(0xFF1C1836)
val AddServerSheetEnd   = Color(0xFF0E101F)

// ── Admin hero ──────────────────────────────────────────────────────────────
val AdminHeroGradStart = Color(0x387C6AF7)
val AdminHeroGradMid   = Color(0xF51A1C34)
val AdminHeroGradEnd   = Color(0xFA0B0F1C)

// ── Misc semantic ───────────────────────────────────────────────────────────
val OverlayBackdrop  = Color(0xCC050412)   // ~80% — strong backdrop (no blur fallback)
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
    overlayBackdrop = Color(0xCC9EAFC0),
    sheetGradStart  = Color(0xFFFFFFFF),
    sheetGradEnd    = Color(0xFFF3F6FF),
    logsSheetStart  = Color(0xFFFFFFFF),
    logsSheetEnd    = Color(0xFFF1F5FF),
    settSheetStart  = Color(0xFFFFFFFF),
    settSheetEnd    = Color(0xFFF6F3FF),
    adminSheetStart = Color(0xFFFFFFFF),
    adminSheetEnd   = Color(0xFFF5F6FF),
    miniToastBg     = Color(0xF5FFFFFF),
    shadowColor     = Color(0x33759EAD),
)

val LocalGhostColors = staticCompositionLocalOf { DarkGhostColors }
