package com.ghoststream.vpn.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val DarkColorScheme = darkColorScheme(
    primary        = AccentPurple,
    secondary      = AccentTeal,
    tertiary       = AccentPurpleLight,
    background     = DarkBackground,
    surface        = DarkSurface,
    surfaceVariant = DarkSurfaceVariant,
    onBackground   = TextPrimary,
    onSurface      = TextPrimary,
    error          = RedError,
)

private val LightColorScheme = lightColorScheme(
    primary        = Color(0xFF6B57F6),
    secondary      = Color(0xFF0F9F85),
    tertiary       = AccentPurpleLight,
    background     = Color(0xFFF7F8FF),
    surface        = Color(0xFFEDF0FF),
    surfaceVariant = Color(0xFFE4E8F8),
    onBackground   = Color(0xFF171B27),
    onSurface      = Color(0xFF171B27),
    error          = RedError,
    outline        = Color(0x2D384468),
)

@Composable
fun GhostStreamTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = false,
    content: @Composable () -> Unit,
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val ctx = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        }
        darkTheme -> DarkColorScheme
        else      -> LightColorScheme
    }

    val ghostColors = if (darkTheme) DarkGhostColors else LightGhostColors

    CompositionLocalProvider(LocalGhostColors provides ghostColors) {
        MaterialTheme(
            colorScheme = colorScheme,
            content = content,
        )
    }
}
