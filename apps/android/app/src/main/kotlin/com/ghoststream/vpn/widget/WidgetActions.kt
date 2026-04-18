package com.ghoststream.vpn.widget

import android.content.Context
import android.content.Intent
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
            // Stop
            val intent = Intent(context, GhostStreamVpnService::class.java)
                .setAction(GhostStreamVpnService.ACTION_STOP)
            context.startService(intent)
        } else {
            // Open app — connecting requires VPN permission + profile selection
            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (launch != null) context.startActivity(launch)
        }
    }
}

class OpenAppAction : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (launch != null) context.startActivity(launch)
    }
}
