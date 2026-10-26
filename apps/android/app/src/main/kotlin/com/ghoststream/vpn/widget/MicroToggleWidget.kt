package com.ghoststream.vpn.widget

import android.content.Context
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.datastore.preferences.core.Preferences
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.currentState
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.glance.text.FontFamily
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.ghoststream.vpn.R

/** Widget A — Micro Toggle (2×1). Status dot + server + toggle button. */
class MicroToggleWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val prefs = currentState<Preferences>()
            val connected = prefs[WidgetState.IS_CONNECTED] ?: false
            val reconnecting = prefs[WidgetState.IS_RECONNECTING] ?: false
            val connecting = (prefs[WidgetState.IS_CONNECTING] ?: false) || reconnecting
            // Connecting / reconnecting count as running: the button stops.
            val running = connected || connecting
            val stateWord = context.getString(
                when {
                    connected -> R.string.widget_online
                    reconnecting -> R.string.widget_reconnecting
                    connecting -> R.string.widget_tuning
                    else -> R.string.widget_offline
                },
            )
            val server = prefs[WidgetState.SERVER_NAME] ?: "GhostStream"

            Row(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(W.bgElev)
                    .cornerRadius(16.dp)
                    .padding(horizontal = 8.dp)
                    .clickable(onClick = actionRunCallback<ToggleVpnAction>()),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Left accent bar when connected
                if (connected) {
                    Box(
                        modifier = GlanceModifier
                            .width(2.dp)
                            .height(28.dp)
                            .background(W.signal)
                            .cornerRadius(1.dp),
                    ) {}
                    Spacer(GlanceModifier.width(8.dp))
                }

                // Status dot
                val dotColor = when {
                    connected -> W.dotGreen
                    connecting -> W.dotOrange
                    else -> W.dotGray
                }
                Box(
                    modifier = GlanceModifier
                        .size(10.dp)
                        .background(dotColor)
                        .cornerRadius(5.dp),
                ) {}

                Spacer(GlanceModifier.width(8.dp))

                // Server info
                Column(modifier = GlanceModifier.defaultWeight()) {
                    Text(
                        text = stateWord.uppercase(),
                        style = TextStyle(
                            color = W.dim,
                            fontSize = 9.sp,
                            fontFamily = FontFamily.Monospace,
                        ),
                        maxLines = 1,
                    )
                    Text(
                        text = server.take(14),
                        style = TextStyle(
                            color = W.bone,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                        ),
                        maxLines = 1,
                    )
                }

                // Action icon area
                Box(
                    modifier = GlanceModifier
                        .size(28.dp)
                        .background(if (running) W.bgElev else W.btnConnect)
                        .cornerRadius(14.dp)
                        .clickable(onClick = actionRunCallback<ToggleVpnAction>()),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = if (running) "\u23FB" else "\u25B6",
                        style = TextStyle(
                            color = if (running) W.danger else W.btnConnectText,
                            fontSize = 12.sp,
                        ),
                    )
                }
            }
        }
    }
}

class MicroToggleWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = MicroToggleWidget()
}
