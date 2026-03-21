package com.ghoststream.vpn

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.core.view.WindowCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.navigation.AppNavigation
import com.ghoststream.vpn.ui.theme.GhostStreamTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        setContent {
            val preferencesStore = remember { PreferencesStore(this@MainActivity) }
            val theme by preferencesStore.theme
                .collectAsStateWithLifecycle(initialValue = "system")

            GhostStreamTheme(
                darkTheme = when (theme) {
                    "dark"  -> true
                    "light" -> false
                    else    -> isSystemInDarkTheme()
                },
            ) {
                AppNavigation()
            }
        }
    }
}
