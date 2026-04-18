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

/** Widget B — Status Panel (2×2). State + server + stats + toggle. */
class StatusPanelWidget : GlanceAppWidget() {
    override val stateDefinition = PreferencesGlanceStateDefinition

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val prefs = currentState<Preferences>()
            val connected = prefs[WidgetState.IS_CONNECTED] ?: false
            val connecting = prefs[WidgetState.IS_CONNECTING] ?: false
            val server = prefs[WidgetState.SERVER_NAME] ?: ""
            val timer = prefs[WidgetState.TIMER_TEXT] ?: "--:--:--"
            val rx = prefs[WidgetState.RX_SPEED] ?: "--"
            val tx = prefs[WidgetState.TX_SPEED] ?: "--"
            val up = prefs[WidgetState.STREAMS_UP] ?: 0
            val total = prefs[WidgetState.STREAMS_TOTAL] ?: 8

            Box(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(W.hair)
                    .cornerRadius(10.dp)
                    .clickable(onClick = actionRunCallback<OpenAppAction>()),
            ) {
                Row(modifier = GlanceModifier.fillMaxSize().background(W.bgElev).cornerRadius(9.dp)) {
                    // Left accent bar
                    if (connected) {
                        Box(
                            modifier = GlanceModifier
                                .width(2.dp)
                                .fillMaxSize()
                                .padding(vertical = 24.dp)
                                .background(W.signal),
                        ) {}
                    }

                    Column(
                        modifier = GlanceModifier
                            .fillMaxSize()
                            .padding(start = 14.dp, end = 14.dp, top = 12.dp, bottom = 10.dp),
                    ) {
                        // Header: brand + timer
                        Row(
                            modifier = GlanceModifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = "GHOST",
                                style = TextStyle(color = W.faint, fontSize = 9.sp, fontFamily = FontFamily.Monospace),
                            )
                            Spacer(GlanceModifier.defaultWeight())
                            Text(
                                text = if (connected) timer else "--:--:--",
                                style = TextStyle(color = W.dim, fontSize = 10.sp, fontFamily = FontFamily.Monospace),
                            )
                        }

                        Spacer(GlanceModifier.height(4.dp))

                        // State headline
                        Text(
                            text = when {
                                connected -> "Online."
                                connecting -> "Tuning..."
                                else -> "Standby."
                            },
                            style = TextStyle(
                                color = when {
                                    connected -> W.signal
                                    connecting -> W.warn
                                    else -> W.faint
                                },
                                fontSize = 18.sp,
                                fontWeight = FontWeight.Bold,
                            ),
                        )

                        // Server name
                        Text(
                            text = server.ifBlank { "---" },
                            style = TextStyle(color = W.dim, fontSize = 10.sp),
                            maxLines = 1,
                        )

                        Spacer(GlanceModifier.defaultWeight())

                        // Separator
                        Box(GlanceModifier.fillMaxWidth().height(1.dp).background(W.hair)) {}

                        Spacer(GlanceModifier.height(6.dp))

                        // Stats row
                        Row(modifier = GlanceModifier.fillMaxWidth()) {
                            // RX
                            Column {
                                Text("RX", style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace))
                                Text(
                                    text = if (connected) rx else "\u2014",
                                    style = TextStyle(color = if (connected) W.signal else W.faint, fontSize = 11.sp, fontWeight = FontWeight.Medium),
                                )
                            }
                            Spacer(GlanceModifier.width(12.dp))
                            // TX
                            Column {
                                Text("TX", style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace))
                                Text(
                                    text = if (connected) tx else "\u2014",
                                    style = TextStyle(color = if (connected) W.warn else W.faint, fontSize = 11.sp, fontWeight = FontWeight.Medium),
                                )
                            }
                            Spacer(GlanceModifier.width(12.dp))
                            // Streams
                            Column {
                                Text("MUX", style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace))
                                Text(
                                    text = "$up/$total",
                                    style = TextStyle(color = W.bone, fontSize = 11.sp, fontWeight = FontWeight.Medium),
                                )
                            }
                        }

                        Spacer(GlanceModifier.height(8.dp))

                        // Toggle button
                        Box(
                            modifier = GlanceModifier
                                .fillMaxWidth()
                                .height(28.dp)
                                .background(if (connected) W.bgElev2 else W.btnConnect)
                                .cornerRadius(2.dp)
                                .clickable(onClick = actionRunCallback<ToggleVpnAction>()),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = if (connected) "DISCONNECT" else "CONNECT",
                                style = TextStyle(
                                    color = if (connected) W.dim else W.btnConnectText,
                                    fontSize = 9.sp,
                                    fontFamily = FontFamily.Monospace,
                                    fontWeight = FontWeight.Medium,
                                ),
                            )
                        }
                    }
                }
            }
        }
    }
}

class StatusPanelWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = StatusPanelWidget()
}
