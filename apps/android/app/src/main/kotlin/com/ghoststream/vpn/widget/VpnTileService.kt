package com.ghoststream.vpn.widget

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import com.ghoststream.vpn.R
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.service.VpnStateManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Quick Settings tile — the same toggle path as the home-screen widgets. */
class VpnTileService : TileService() {

    private var scope: CoroutineScope? = null

    override fun onStartListening() {
        scope = MainScope().also { s ->
            s.launch { VpnStateManager.derivedVpnState.collect(::render) }
        }
    }

    override fun onStopListening() {
        scope?.cancel()
        scope = null
    }

    override fun onClick() {
        // Turning the VPN off from the lock screen must not be possible.
        if (isLocked) unlockAndRun(::toggle) else toggle()
    }

    private fun toggle() {
        if (toggleVpn(this)) return
        // First connect needs the system VPN consent — only the app can ask.
        val launch = packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, launch, PendingIntent.FLAG_IMMUTABLE),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(launch)
        }
    }

    private fun render(state: VpnState) {
        val tile = qsTile ?: return
        tile.state = when (state) {
            is VpnState.Disconnected, is VpnState.Error -> Tile.STATE_INACTIVE
            else -> Tile.STATE_ACTIVE
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when (state) {
                is VpnState.Connecting -> getString(R.string.widget_tuning)
                is VpnState.Reconnecting -> getString(R.string.widget_reconnecting)
                else -> null
            }
        }
        tile.updateTile()
    }
}
