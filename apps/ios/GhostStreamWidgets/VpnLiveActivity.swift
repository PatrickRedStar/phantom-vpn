// Live Activity: Dynamic Island (shield + session timer) and the lock-screen
// banner (profile, state, timer · route, Disconnect). Started/updated by the
// app (SystemSurfaces); the timer runs on its own. No rates: the app is
// suspended in the background and they would freeze.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct VpnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: GhostActivityAttributes.self) { context in
            LockScreenView(context: context)
                .environment(\.locale, SurfaceState.locale)
                .activityBackgroundTint(GS.bg.opacity(0.62))
                .activitySystemActionForegroundColor(GS.bone)
        } dynamicIsland: { context in
            let tint = context.state.reconnecting ? GS.warn : GS.signal
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "shield")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 66 pt holds "9:59:59" in Departure Mono 14 (62 pt);
                    // the inset keeps the digits off the island's corner.
                    SessionTimer(start: context.attributes.sessionStart)
                        .font(GS.mono(14))
                        .foregroundColor(tint)
                        .frame(width: 66, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LockScreenView(context: context, showsTimer: false)
                        .environment(\.locale, SurfaceState.locale)
                }
            } compactLeading: {
                Image(systemName: "shield")
                    .foregroundColor(tint)
            } compactTrailing: {
                SessionTimer(start: context.attributes.sessionStart)
                    .font(GS.mono(11))
                    .foregroundColor(tint)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: "shield.fill")
                    .foregroundColor(tint)
            }
            .keylineTint(tint)
        }
    }
}

/// Dynamic Island timer. Text(timerInterval:) reserves the width of the
/// longest value in its range: up to distantFuture that is a 14-digit hour
/// count, wider than the region, and the digits got clipped. The island
/// shows an activity for at most 8 h, so the range stops at 9:59:59.
private struct SessionTimer: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...start.addingTimeInterval(10 * 3600 - 1), countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<GhostActivityAttributes>
    /// The expanded island has its own timer in the trailing region.
    var showsTimer = true

    var body: some View {
        let state = context.state
        let kind: SurfaceState.Kind = state.reconnecting ? .reconnecting : .connected
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "GHOSTSTREAM · \(context.attributes.profileName.uppercased())")
                    .font(GS.mono(10))
                    .tracking(1.6)
                    .foregroundColor(GS.label)
                    .lineLimit(1)
                (GS.stateWord(kind)
                    .foregroundColor(GS.headlineColor(kind))
                 + Text(".").foregroundColor(GS.bone))
                    .font(GS.grotesk(26))
                    .tracking(-0.52)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                // Timer first: a long relay host is cut at the tail, not it.
                (showsTimer
                    ? Text(context.attributes.sessionStart, style: .timer) + Text(verbatim: " · ") + route
                    : route)
                .font(GS.jet(11))
                .foregroundColor(GS.label)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(intent: DisconnectVPNIntent()) {
                Image(systemName: "power")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(GS.bone)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("activity.disconnect", tableName: "Widgets"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var route: Text {
        if let host = context.attributes.relayHost {
            return Text("activity.route.relay \(host)", tableName: "Widgets")
        }
        return Text("activity.route.direct", tableName: "Widgets")
    }
}
