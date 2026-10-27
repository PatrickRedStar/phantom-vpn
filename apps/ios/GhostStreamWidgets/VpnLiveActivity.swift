// Live Activity: Dynamic Island (shield + session timer) and the lock-screen
// banner (profile, state, rates, Disconnect). Started/updated by the app
// (SystemSurfaces); the timer runs on its own. Stale content (app suspended)
// shows the timer instead of rates.

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
                    SessionTimer(start: context.attributes.sessionStart)
                        .font(GS.mono(14))
                        .foregroundColor(tint)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LockScreenView(context: context)
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

private struct SessionTimer: View {
    let start: Date

    var body: some View {
        Text(timerInterval: start...Date.distantFuture, countsDown: false)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<GhostActivityAttributes>
    @Environment(\.locale) private var locale

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
                Group {
                    if context.isStale {
                        SessionTimer(start: context.attributes.sessionStart)
                            .multilineTextAlignment(.leading)
                    } else {
                        Text(
                            "activity.rates \(rate(state.rxMBps)) \(rate(state.txMBps)) \(state.streamsUp) \(state.streamsTotal)",
                            tableName: "Widgets"
                        )
                    }
                }
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

    private func rate(_ megabytes: Double) -> String {
        megabytes.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }
}
