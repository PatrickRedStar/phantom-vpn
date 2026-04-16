package com.ghoststream.vpn

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import androidx.core.view.WindowCompat
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.navigation.AppNavigation
import com.ghoststream.vpn.ui.theme.GhostStreamTheme
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // Apply language override before inflating any views.
        val prefs = PreferencesStore(this)
        val lang = runCatching { runBlocking { prefs.languageOverride.first() } }.getOrNull()
        val locales = if (lang.isNullOrBlank()) LocaleListCompat.getEmptyLocaleList()
                      else LocaleListCompat.forLanguageTags(lang)
        AppCompatDelegate.setApplicationLocales(locales)

        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        setContent {
            GhostStreamTheme {
                AppNavigation()
            }
        }
    }
}
