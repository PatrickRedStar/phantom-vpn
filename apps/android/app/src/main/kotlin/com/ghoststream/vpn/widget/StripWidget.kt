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

/** Widget C — Dashboard Strip (4×1). Horizontal: dot + server + timer + speeds + toggle. */
class StripWidget : GlanceAppWidget() {
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

            Box(
                modifier = GlanceModifier
                    .fillMaxSize()
                    .background(W.hair)
                    .cornerRadius(10.dp)
                    .clickable(onClick = actionRunCallback<OpenAppAction>()),
            ) {
                Row(
                    modifier = GlanceModifier
                        .fillMaxSize()
                        .background(W.bgElev)
                        .cornerRadius(9.dp)
                        .padding(horizontal = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    // Left accent bar
                    if (connected) {
                        Box(
                            modifier = GlanceModifier
                                .width(2.dp)
                                .height(28.dp)
                                .background(W.signal)
                                .cornerRadius(1.dp),
                        ) {}
                        Spacer(GlanceModifier.width(10.dp))
                    }

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

                    // Server + status
                    Column(modifier = GlanceModifier.defaultWeight()) {
                        Text(
                            text = server.ifBlank { "GhostStream" }.take(16),
                            style = TextStyle(
                                color = W.bone,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Bold,
                            ),
                            maxLines = 1,
                        )
                        Text(
                            text = when {
                                connected -> "ONLINE"
                                connecting -> "TUNING"
                                else -> "OFFLINE"
                            },
                            style = TextStyle(
                                color = W.dim,
                                fontSize = 9.sp,
                                fontFamily = FontFamily.Monospace,
                            ),
                        )
                    }

                    // Timer
                    Text(
                        text = if (connected) timer else "--:--:--",
                        style = TextStyle(
                            color = W.dim,
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                        ),
                    )

                    Spacer(GlanceModifier.width(14.dp))

                    // Separator
                    Box(GlanceModifier.width(1.dp).height(24.dp).background(W.hair)) {}

                    Spacer(GlanceModifier.width(14.dp))

                    // RX / TX
                    Column(horizontalAlignment = Alignment.End) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "RX ",
                                style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace),
                            )
                            Text(
                                text = if (connected) rx else "\u2014",
                                style = TextStyle(
                                    color = if (connected) W.signal else W.faint,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Medium,
                                ),
                            )
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "TX ",
                                style = TextStyle(color = W.faint, fontSize = 8.sp, fontFamily = FontFamily.Monospace),
                            )
                            Text(
                                text = if (connected) tx else "\u2014",
                                style = TextStyle(
                                    color = if (connected) W.warn else W.faint,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Medium,
                                ),
                            )
                        }
                    }

                    Spacer(GlanceModifier.width(14.dp))

                    // Toggle button
                    Box(
                        modifier = GlanceModifier
                            .size(28.dp)
                            .background(if (connected) W.bgElev2 else W.btnConnect)
                            .cornerRadius(14.dp)
                            .clickable(onClick = actionRunCallback<ToggleVpnAction>()),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            text = if (connected) "\u23FB" else "\u25B6",
                            style = TextStyle(
                                color = if (connected) W.dim else W.btnConnectText,
                                fontSize = 12.sp,
                            ),
                        )
                    }
                }
            }
        }
    }
}

class StripWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget = StripWidget()
}
