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

/** Widget D — Full Dashboard (4×2). All stats + visual bar chart approximation. */
class FullDashboardWidget : GlanceAppWidget() {
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
            val timer = prefs[WidgetState.TIMER_TEXT] ?: "--:--:--"
            val rx = prefs[WidgetState.RX_SPEED] ?: "--"
            val tx = prefs[WidgetState.TX_SPEED] ?: "--"
            val up = prefs[WidgetState.STREAMS_UP] ?: 0
            val total = prefs[WidgetState.STREAMS_TOTAL] ?: 8

            Column(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(W.bgElev)
                    .cornerRadius(16.dp)
                    .padding(8.dp)
                    .clickable(onClick = actionRunCallback<OpenAppAction>()),
            ) {
                    // Top accent bar when connected
                    if (connected) {
                        Box(
                            modifier = GlanceModifier
                                .fillMaxWidth()
                                .height(2.dp)
                                .background(W.signal)
                                .cornerRadius(1.dp),
                        ) {}
                        Spacer(GlanceModifier.height(4.dp))
                    }
                        // Row 1: Brand dot + "Ghoststream" + Timer
                        Row(
                            modifier = GlanceModifier.fillMaxWidth(),
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
                            Spacer(GlanceModifier.width(8.dp))
                            Text(
                                text = "G",
                                style = TextStyle(
                                    color = W.signal,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold,
                                ),
                            )
                            Text(
                                text = "hoststream",
                                style = TextStyle(
                                    color = W.bone,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold,
                                ),
                            )
                            Spacer(GlanceModifier.defaultWeight())
                            Text(
                                text = if (connected) timer else "--:--:--",
                                style = TextStyle(
                                    color = W.dim,
                                    fontSize = 10.sp,
                                    fontFamily = FontFamily.Monospace,
                                ),
                            )
                        }

                        Spacer(GlanceModifier.height(8.dp))

                        // Separator
                        Box(GlanceModifier.fillMaxWidth().height(1.dp).background(W.hair)) {}

                        Spacer(GlanceModifier.height(8.dp))

                        // Stats: RX, TX, STREAMS stacked on right side
                        Row(modifier = GlanceModifier.fillMaxWidth()) {
                            // Stream bars (left, visual)
                            Column(modifier = GlanceModifier.defaultWeight()) {
                                Row(
                                    modifier = GlanceModifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    for (i in 0 until total.coerceAtMost(12)) {
                                        if (i > 0) Spacer(GlanceModifier.width(2.dp))
                                        Box(
                                            modifier = GlanceModifier
                                                .height(4.dp)
                                                .defaultWeight()
                                                .background(if (i < up) W.signal else W.hair)
                                                .cornerRadius(2.dp),
                                        ) {}
                                    }
                                }
                            }
                            Spacer(GlanceModifier.width(14.dp))
                            // Stats column (right)
                            Column(horizontalAlignment = Alignment.End) {
                                Text(
                                    "RX",
                                    style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace),
                                )
                                Text(
                                    text = if (connected) rx else "\u2014",
                                    style = TextStyle(
                                        color = if (connected) W.signal else W.faint,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium,
                                    ),
                                )
                                Spacer(GlanceModifier.height(4.dp))
                                Text(
                                    "TX",
                                    style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace),
                                )
                                Text(
                                    text = if (connected) tx else "\u2014",
                                    style = TextStyle(
                                        color = if (connected) W.warn else W.faint,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium,
                                    ),
                                )
                                Spacer(GlanceModifier.height(4.dp))
                                Text(
                                    "STREAMS",
                                    style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace),
                                )
                                Text(
                                    text = "$up/$total",
                                    style = TextStyle(
                                        color = W.bone,
                                        fontSize = 14.sp,
                                        fontWeight = FontWeight.Medium,
                                    ),
                                )
                            }
                        }

                        Spacer(GlanceModifier.defaultWeight())

                        // Footer: server name + button
                        Text(
                            text = if (connecting) stateWord else server.take(18),
                            style = TextStyle(
                                color = W.dim,
                                fontSize = 9.sp,
                            ),
                            maxLines = 1,
                        )

                        Spacer(GlanceModifier.height(4.dp))

                        // Toggle button row
                        Box(
                            modifier = GlanceModifier
                                .fillMaxWidth()
                                .height(26.dp)
                                .background(if (running) W.hair else W.btnConnect)
                                .cornerRadius(4.dp)
                                .clickable(onClick = actionRunCallback<ToggleVpnAction>()),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = context.getString(
                                    if (running) R.string.action_disconnect else R.string.action_connect,
                                ).uppercase(),
                                style = TextStyle(
                                    color = if (running) W.dim else W.btnConnectText,
                                    fontSize = 8.sp,
                                    fontFamily = FontFamily.Monospace,
                                    fontWeight = FontWeight.Bold,
                                ),
                            )
                        }
            }
        }
    }
}

class FullDashboardWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = FullDashboardWidget()
}
