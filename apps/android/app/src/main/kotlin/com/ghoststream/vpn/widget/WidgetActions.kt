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

/**
 * Connect / disconnect from outside the app (home-screen widgets, Quick
 * Settings tile). Returns false when the app has to be opened instead:
 * VPN consent not granted yet, or the service couldn't be started.
 */
fun toggleVpn(context: Context): Boolean = runCatching {
    when (VpnStateManager.state.value) {
        // v0.27.0 (W5): already tearing down — a second tap must not race a
        // fresh start past the Service's tunnelGeneration guard.
        is VpnState.Disconnecting -> Unit
        is VpnState.Disconnected,
        is VpnState.Error -> {
            if (VpnService.prepare(context) != null) return false
            // Service restores the last-used config itself.
            context.startForegroundService(
                Intent(context, GhostStreamVpnService::class.java)
                    .setAction(GhostStreamVpnService.ACTION_START),
            )
        }
        // Connecting / reconnecting count as running: the tap cancels.
        else -> context.startService(
            Intent(context, GhostStreamVpnService::class.java)
                .setAction(GhostStreamVpnService.ACTION_STOP),
        )
    }
    true
}.getOrDefault(false)

class ToggleVpnAction : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        if (!toggleVpn(context)) openApp(context)
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
