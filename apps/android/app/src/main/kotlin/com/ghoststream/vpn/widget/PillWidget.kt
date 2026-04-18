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
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.state.PreferencesGlanceStateDefinition
import androidx.glance.text.FontFamily
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle

/** Widget E — Compact Pill (4×1). Capsule shape, ultra-minimal: dot + label + speed. */
class PillWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val prefs = currentState<Preferences>()
            val connected = prefs[WidgetState.IS_CONNECTED] ?: false
            val connecting = prefs[WidgetState.IS_CONNECTING] ?: false
            val rx = prefs[WidgetState.RX_SPEED] ?: "--"
            val tx = prefs[WidgetState.TX_SPEED] ?: "--"
            val server = prefs[WidgetState.SERVER_NAME] ?: ""
            val timer = prefs[WidgetState.TIMER_TEXT] ?: "--:--:--"

            Row(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(W.bgElev)
                    .cornerRadius(28.dp)
                    .padding(start = 16.dp, end = 6.dp)
                    .clickable(onClick = actionRunCallback<OpenAppAction>()),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                    // Status dot
                    val dotColor = when {
                        connected -> W.dotGreen
                        connecting -> W.dotOrange
                        else -> W.dotGray
                    }
                    Box(
                        modifier = GlanceModifier
                            .size(8.dp)
                            .background(dotColor)
                            .cornerRadius(4.dp),
                    ) {}

                    Spacer(GlanceModifier.width(10.dp))

                    // Server name
                    Text(
                        text = when {
                            connected -> server.ifBlank { "GhostStream" }.take(12)
                            connecting -> "Tuning..."
                            else -> server.ifBlank { "GhostStream" }.take(12)
                        },
                        style = TextStyle(
                            color = if (connected) W.bone else W.dim,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                        ),
                        maxLines = 1,
                    )

                    if (connected) {
                        // Timer
                        Spacer(GlanceModifier.width(8.dp))
                        Text(
                            text = timer,
                            style = TextStyle(
                                color = W.dim,
                                fontSize = 10.sp,
                                fontFamily = FontFamily.Monospace,
                            ),
                        )

                        Spacer(GlanceModifier.defaultWeight())

                        // Speed indicators
                        Text(
                            text = "\u2193$rx",
                            style = TextStyle(
                                color = W.signal,
                                fontSize = 9.sp,
                            ),
                        )
                        Spacer(GlanceModifier.width(6.dp))
                        Text(
                            text = "\u2191$tx",
                            style = TextStyle(
                                color = W.warn,
                                fontSize = 9.sp,
                            ),
                        )
                    } else {
                        Spacer(GlanceModifier.width(8.dp))
                        Text(
                            text = "Offline",
                            style = TextStyle(
                                color = W.faint,
                                fontSize = 10.sp,
                            ),
                        )
                        Spacer(GlanceModifier.defaultWeight())
                    }

                    Spacer(GlanceModifier.width(6.dp))

                    // Toggle button (44dp circle like mockup)
                    Box(
                        modifier = GlanceModifier
                            .size(44.dp)
                            .background(if (connected) W.bgElev else W.btnConnect)
                            .cornerRadius(22.dp)
                            .clickable(onClick = actionRunCallback<ToggleVpnAction>()),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = if (connected) "\u23FB" else "\u25B6",
                            style = TextStyle(
                                color = if (connected) W.danger else W.btnConnectText,
                                fontSize = 16.sp,
                            ),
                        )
                    }
            }
        }
    }
}

class PillWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = PillWidget()
}
