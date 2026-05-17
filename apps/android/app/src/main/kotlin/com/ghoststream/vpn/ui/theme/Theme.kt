package com.ghoststream.vpn.ui.theme

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.ui.Modifier
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
            // v0.26.3: edge-to-edge — system bars become transparent so
            // our `C.bg` colour shows through under both the status bar
            // and the gesture pill area. Without this, on light theme
            // Android draws a white nav-bar strip under the dark app
            // content (and a less visible strip on dark theme too).
            // The deprecation note is acknowledged: navigationBarColor
            // is the only working knob across API 26..36 — the new
            // `enableEdgeToEdge(SystemBarStyle)` API still resolves to
            // setting these properties underneath.
            @Suppress("DEPRECATION")
            window.navigationBarColor = android.graphics.Color.TRANSPARENT
            @Suppress("DEPRECATION")
            window.statusBarColor = android.graphics.Color.TRANSPARENT
        }
    }

    CompositionLocalProvider(
        LocalIsDark provides isDark,
        LocalGsColors provides gsColors,
    ) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography  = GsTypography,
        ) {
            // Root background paints under transparent system bars so the
            // gesture pill / status bar areas inherit our app colour
            // instead of showing the OS default.
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(gsColors.bg),
            ) {
                content()
            }
        }
    }
}
