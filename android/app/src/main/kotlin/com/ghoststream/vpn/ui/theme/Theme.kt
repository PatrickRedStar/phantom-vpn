package com.ghoststream.vpn.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.data.PreferencesStore

private val GsDarkColorScheme = darkColorScheme(
    primary          = GsSignal,
    onPrimary        = GsBg,
    secondary        = GsWarn,
    onSecondary      = GsBg,
    tertiary         = GsSignal,
    background       = GsBg,
    onBackground     = GsBone,
    surface          = GsBgElev,
    onSurface        = GsBone,
    surfaceVariant   = GsBgElev2,
    onSurfaceVariant = GsTextDim,
    outline          = GsHair,
    outlineVariant   = GsHairBold,
    error            = GsDanger,
    onError          = GsBg,
    errorContainer   = GsDanger.copy(alpha = 0.15f),
    onErrorContainer = GsDanger,
)

private val GsLightColorScheme = lightColorScheme(
    primary          = GsLightSignal,
    onPrimary        = GsLightBg,
    secondary        = GsLightWarn,
    onSecondary      = GsLightBg,
    tertiary         = GsLightSignal,
    background       = GsLightBg,
    onBackground     = GsLightInk,
    surface          = GsLightBgElev,
    onSurface        = GsLightInk,
    surfaceVariant   = GsLightBgElev2,
    onSurfaceVariant = GsLightTextDim,
    outline          = GsLightHair,
    outlineVariant   = GsLightHairBold,
    error            = GsLightDanger,
    onError          = GsLightBg,
    errorContainer   = GsLightDanger.copy(alpha = 0.15f),
    onErrorContainer = GsLightDanger,
)

/** true = dark mode active in current composition. */
val LocalIsDark = compositionLocalOf { true }

@Composable
fun GhostStreamTheme(
    themeOverride: String? = null, // "dark" | "light" | "system" | null
    content: @Composable () -> Unit,
) {
    val themeSetting = themeOverride ?: run {
        val ctx = LocalContext.current.applicationContext
        val prefs = PreferencesStore(ctx)
        prefs.theme.collectAsStateWithLifecycle(initialValue = "system").value
    }

    val isDark = when (themeSetting) {
        "dark"  -> true
        "light" -> false
        else    -> isSystemInDarkTheme()
    }

    val colorScheme = if (isDark) GsDarkColorScheme else GsLightColorScheme

    val gsColors = if (isDark) GsDarkColors else GsLightColors

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            val ctrl = WindowCompat.getInsetsController(window, view)
            ctrl.isAppearanceLightStatusBars = !isDark
            ctrl.isAppearanceLightNavigationBars = !isDark
        }
    }

    CompositionLocalProvider(
        LocalIsDark provides isDark,
        LocalGsColors provides gsColors,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography  = GsTypography,
            content     = content,
        )
    }
}
