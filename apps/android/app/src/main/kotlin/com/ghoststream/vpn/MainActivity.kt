package com.ghoststream.vpn

import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.app.AppCompatDelegate
import androidx.core.os.LocaleListCompat
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.navigation.AppNavigation
import com.ghoststream.vpn.ui.theme.GhostStreamTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.firstOrNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : AppCompatActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // v0.25.1 W3-4 fix: do NOT block the main thread reading DataStore
        // for the locale override. On low-end devices (Android Go, 1 GB RAM)
        // a cold DataStore read can take 300-800 ms before super.onCreate,
        // producing a white-screen / ANR window.
        //
        // Trade-off: the first frame renders in the system default locale.
        // Once the async read completes we call AppCompatDelegate.setApp-
        // licationLocales(), which the platform persists and which forces
        // a fast Activity recreate with the user's locale applied. This is
        // a sub-second visible blip on cold start; the alternative (blocking
        // read) is an ANR.
        //
        // TODO(v0.26): migrate locale storage to AppCompatDelegate.setApp-
        // licationLocales() as the single source of truth — getApplication-
        // Locales() returns synchronously from system prefs, so no DataStore
        // read is needed at all. Requires touching SettingsViewModel +
        // PreferencesStore (out of scope for Batch I).
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        setContent {
            GhostStreamTheme {
                AppNavigation()
            }
        }

        lifecycleScope.launch {
            val lang = runCatching {
                withContext(Dispatchers.IO) {
                    PreferencesStore(applicationContext).languageOverride.firstOrNull()
                }
            }.getOrNull()
            val locales = if (lang.isNullOrBlank()) LocaleListCompat.getEmptyLocaleList()
                          else LocaleListCompat.forLanguageTags(lang)
            // setApplicationLocales hops to the main thread itself and is
            // safe to call after super.onCreate — the platform will recreate
            // the Activity with the new locale if it differs from the
            // current configuration.
            AppCompatDelegate.setApplicationLocales(locales)
        }
    }
}
