package com.ghoststream.vpn.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat
import com.ghoststream.vpn.data.PreferencesStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Fires on BOOT_COMPLETED (and on app update). If the user enabled auto-start
 * and had an active tunnel before the reboot, spin up the VPN service with
 * null intent — the service restores params from prefs.
 *
 * v0.25.1 W3-3 fix: do NOT read DataStore on the main broadcast thread.
 * BroadcastReceiver.onReceive runs on the main thread with a 10s ANR budget;
 * on cold boot DataStore initialization can easily eat 1-3s plus IO overhead,
 * so we hop to Dispatchers.IO via goAsync() and start the service from the
 * main thread when ready.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        // BroadcastReceiver runs on main thread with a 10s timeout. DataStore
        // reads on cold boot can take 1-3s, plus IO-thread switch overhead.
        // goAsync() promises Android we'll finish eventually off-thread.
        val pendingResult = goAsync()
        val appContext = context.applicationContext

        CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
            try {
                val prefs = PreferencesStore(appContext)
                val autoStart = runCatching { prefs.autoStartOnBoot.first() }
                    .getOrDefault(false)
                if (!autoStart) return@launch
                // wasRunningBlocking() uses runBlocking under the hood but we
                // are already on Dispatchers.IO so the additional blocking is
                // bounded and not on the main broadcast thread.
                if (!prefs.wasRunningBlocking()) return@launch

                Log.i("GhostStreamBoot", "Auto-starting VPN service after boot")
                // ContextCompat.startForegroundService must be invoked from
                // the main thread.
                withContext(Dispatchers.Main) {
                    val svc = Intent(appContext, GhostStreamVpnService::class.java)
                    runCatching { ContextCompat.startForegroundService(appContext, svc) }
                        .onFailure { Log.w("GhostStreamBoot", "Failed to start service", it) }
                }
            } catch (t: Throwable) {
                Log.e("GhostStreamBoot", "auto-start failed", t)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
