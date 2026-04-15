package com.ghoststream.vpn.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.ghoststream.vpn.data.PreferencesStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking

/**
 * Fires on BOOT_COMPLETED (and on app update). If the user enabled auto-start
 * and had an active tunnel before the reboot, spin up the VPN service with
 * null intent — the service restores params from prefs.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) return

        val prefs = PreferencesStore(context.applicationContext)
        val autoStart = runCatching {
            runBlocking { prefs.autoStartOnBoot.first() }
        }.getOrDefault(false)
        if (!autoStart) return
        if (!prefs.wasRunningBlocking()) return

        Log.i("GhostStreamBoot", "Auto-starting VPN service after boot")
        val svc = Intent(context, GhostStreamVpnService::class.java)
        runCatching { context.startForegroundService(svc) }
            .onFailure { Log.w("GhostStreamBoot", "Failed to start service", it) }
    }
}
