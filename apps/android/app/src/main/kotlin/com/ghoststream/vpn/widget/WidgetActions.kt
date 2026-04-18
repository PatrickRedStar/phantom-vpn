package com.ghoststream.vpn.widget

import android.content.Context
import android.content.Intent
import android.net.VpnService
import androidx.glance.GlanceId
import androidx.glance.action.ActionParameters
import androidx.glance.appwidget.action.ActionCallback
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.service.VpnStateManager

class ToggleVpnAction : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        val state = VpnStateManager.state.value
        if (state is VpnState.Connected || state is VpnState.Connecting) {
            // Disconnect
            try {
                val intent = Intent(context, GhostStreamVpnService::class.java)
                    .setAction(GhostStreamVpnService.ACTION_STOP)
                context.startService(intent)
            } catch (_: Exception) {
                openApp(context)
            }
        } else {
            // Connect: check if VPN permission is already granted
            val prepare = VpnService.prepare(context)
            if (prepare == null) {
                // Permission granted — start service directly.
                // Service restores last-used config from SharedPreferences.
                try {
                    val intent = Intent(context, GhostStreamVpnService::class.java)
                        .setAction(GhostStreamVpnService.ACTION_START)
                    context.startForegroundService(intent)
                } catch (_: Exception) {
                    openApp(context)
                }
            } else {
                // Permission not granted (first time) — must open app
                openApp(context)
            }
        }
    }
}

class OpenAppAction : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        openApp(context)
    }
}

private fun openApp(context: Context) {
    val launch = context.packageManager
        .getLaunchIntentForPackage(context.packageName)
        ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    if (launch != null) context.startActivity(launch)
}
