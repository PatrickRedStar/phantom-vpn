package com.ghoststream.vpn.widget

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.glance.appwidget.GlanceAppWidgetManager
import androidx.glance.appwidget.state.updateAppWidgetState
import androidx.glance.appwidget.updateAll
import androidx.glance.state.PreferencesGlanceStateDefinition

object WidgetState {
    val IS_CONNECTED  = booleanPreferencesKey("vpn_connected")
    val IS_CONNECTING = booleanPreferencesKey("vpn_connecting")
    val SERVER_NAME   = stringPreferencesKey("vpn_server")
    val TIMER_TEXT    = stringPreferencesKey("vpn_timer")
    val RX_SPEED      = stringPreferencesKey("vpn_rx")
    val TX_SPEED      = stringPreferencesKey("vpn_tx")
    val STREAMS_UP    = intPreferencesKey("vpn_streams_up")
    val STREAMS_TOTAL = intPreferencesKey("vpn_streams_total")

    /** Call from VPN service whenever state changes. */
    suspend fun push(
        context: Context,
        connected: Boolean,
        connecting: Boolean = false,
        serverName: String = "",
        timer: String = "--:--:--",
        rxSpeed: String = "--",
        txSpeed: String = "--",
        streamsUp: Int = 0,
        streamsTotal: Int = 8,
    ) {
        val widgetClasses = listOf(
            MicroToggleWidget::class.java,
            StatusPanelWidget::class.java,
            StripWidget::class.java,
            FullDashboardWidget::class.java,
            PillWidget::class.java,
        )
        val manager = GlanceAppWidgetManager(context)
        for (cls in widgetClasses) {
            val ids = manager.getGlanceIds(cls)
            for (id in ids) {
                updateAppWidgetState(context, PreferencesGlanceStateDefinition, id) { prefs ->
                    prefs.toMutablePreferences().apply {
                        this[IS_CONNECTED] = connected
                        this[IS_CONNECTING] = connecting
                        this[SERVER_NAME] = serverName
                        this[TIMER_TEXT] = timer
                        this[RX_SPEED] = rxSpeed
                        this[TX_SPEED] = txSpeed
                        this[STREAMS_UP] = streamsUp
                        this[STREAMS_TOTAL] = streamsTotal
                    }
                }
            }
        }
        // Trigger re-render
        widgetClasses.forEachIndexed { i, _ ->
            when (i) {
                0 -> MicroToggleWidget().updateAll(context)
                1 -> StatusPanelWidget().updateAll(context)
                2 -> StripWidget().updateAll(context)
                3 -> FullDashboardWidget().updateAll(context)
                4 -> PillWidget().updateAll(context)
            }
        }
    }
}
