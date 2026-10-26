package com.ghoststream.vpn

import android.app.Application
import android.util.Log
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.service.LogPersister
import com.ghoststream.vpn.service.VpnStateManager
import com.ghoststream.vpn.widget.WidgetState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Application class — pre-warms critical singletons so widgets and UI
 * don't show stale state after process restart (cold start without
 * Service/Activity), and so DataStore reads happen off-main-thread before
 * MainActivity starts rendering. v0.25.1 W3-11.
 *
 * Why: after the OS kills the app process (low memory, swipe-away), any
 * launcher widgets still render whatever state Glance has cached — often a
 * green "on" for a tunnel that died with the process.
 */
class MyApplication : Application() {

    private val appScope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    override fun onCreate() {
        super.onCreate()

        // Touch VpnStateManager so its derivedState flow lights up before
        // any subscriber arrives. Cheap (singleton init).
        @Suppress("UNUSED_EXPRESSION") VpnStateManager

        // v0.27.0 (W7): persist Rust log frames on Application scope —
        // survives every Service create/destroy cycle. Previously bound to
        // GhostStreamVpnService.serviceScope, which was cancelled in
        // onDestroy when the user disconnected. LogPersister's
        // `if (started) return` short-circuit then prevented the *next*
        // Service.onCreate from re-launching the collector, so persist
        // file stopped growing after the first session and reconnect
        // events from later sessions were lost. Application.onCreate runs
        // once per process — appScope lives as long as the process does.
        LogPersister.start(this, appScope)

        // A fresh process has no tunnel in it, whatever the widget cached.
        // If the user had VPN on, render "connecting" only when something will
        // actually bring it back (auto-start); otherwise "off". The service
        // overwrites this with the truth as soon as it runs — including the
        // restart after a process kill and the one after an app update.
        appScope.launch(Dispatchers.IO) {
            try {
                val prefs = PreferencesStore(this@MyApplication)
                val wasRunning = runCatching { prefs.wasRunningBlocking() }.getOrDefault(false)
                if (wasRunning) {
                    val autoStart = runCatching { prefs.autoStartOnBoot.first() }.getOrDefault(false)
                    WidgetState.push(
                        context = this@MyApplication,
                        connected = false,
                        connecting = autoStart,
                        serverName = "",
                    )
                }
            } catch (t: Throwable) {
                Log.w("MyApplication", "widget pre-warm failed", t)
            }
        }
    }
}
