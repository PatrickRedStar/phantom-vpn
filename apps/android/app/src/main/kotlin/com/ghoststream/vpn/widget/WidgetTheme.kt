package com.ghoststream.vpn.widget

import androidx.compose.ui.graphics.Color
import androidx.glance.color.ColorProvider as DayNight

/** GhostStream Phosphor palette adapted for Glance widgets (day/night auto-switch). */
object W {
    // Backgrounds
    val bg       = DayNight(day = Color(0xFFF1ECDC), night = Color(0xFF0A0908))
    val bgElev   = DayNight(day = Color(0xFFE8E2D0), night = Color(0xFF12110E))
    val bgElev2  = DayNight(day = Color(0xFFDDD6C2), night = Color(0xFF17150F))

    // Borders / hairlines
    val hair     = DayNight(day = Color(0xFFCBC3AD), night = Color(0xFF2A2619))
    val hairBold = DayNight(day = Color(0xFFB5AD96), night = Color(0xFF3D3828))

    // Text
    val bone     = DayNight(day = Color(0xFF16130C), night = Color(0xFFE8E2D0))
    val dim      = DayNight(day = Color(0xFF5A5240), night = Color(0xFF948A6F))
    val faint    = DayNight(day = Color(0xFF948A6F), night = Color(0xFF5A5240))

    // Accents
    val signal     = DayNight(day = Color(0xFF4A6010), night = Color(0xFFC4FF3E))
    val signalDim  = DayNight(day = Color(0xFF7A9B30), night = Color(0xFF4A6010))
    val warn       = DayNight(day = Color(0xFFD4600A), night = Color(0xFFFF7A3D))
    val danger     = DayNight(day = Color(0xFFCC3322), night = Color(0xFFFF4A3D))

    // Button backgrounds
    val btnConnect     = DayNight(day = Color(0xFF4A6010), night = Color(0xFFC4FF3E))
    val btnConnectText = DayNight(day = Color(0xFFF1ECDC), night = Color(0xFF0A0908))
    val btnDisconnect  = DayNight(day = Color(0xFFB5AD96), night = Color(0xFF3D3828))

    // Status dots (theme-aware like in mockup)
    val dotGreen  = DayNight(day = Color(0xFF4A6010), night = Color(0xFFC4FF3E))
    val dotOrange = DayNight(day = Color(0xFFD4600A), night = Color(0xFFFF7A3D))
    val dotGray   = DayNight(day = Color(0xFFB5AD96), night = Color(0xFF5A5240))
}
