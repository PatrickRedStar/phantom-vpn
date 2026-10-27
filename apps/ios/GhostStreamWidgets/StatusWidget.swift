// Home-screen widget 2×2: brand, status dot, state headline, "timer · route"
// and a Connect / Disconnect button. The timeline is a single entry; the app
// and the tunnel extension reload it when the VPN state changes — so nothing
// here may change between reloads (no k/N streams, no rates).

import AppIntents
import SwiftUI
import WidgetKit

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GhostStreamStatus", provider: Provider()) { entry in
            StatusWidgetView(state: entry.state)
                .environment(\.locale, SurfaceState.locale)
                .containerBackground(GS.bg, for: .widget)
        }
        .configurationDisplayName(Text("widget.name", tableName: "Widgets"))
        .description(Text("widget.description", tableName: "Widgets"))
        .supportedFamilies([.systemSmall])
    }

    struct Entry: TimelineEntry {
        let date: Date
        let state: SurfaceState
    }

    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry {
            Entry(date: .now, state: SurfaceState())
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
            completion(Entry(date: .now, state: SurfaceState.load()))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
            completion(Timeline(entries: [Entry(date: .now, state: SurfaceState.load())], policy: .never))
        }
    }
}

struct StatusWidgetView: View {
    let state: SurfaceState

    private var live: Bool { state.kind == .connected || state.kind == .reconnecting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                (Text("G").foregroundColor(GS.signal) + Text("hoststream").foregroundColor(GS.bone))
                    .font(GS.grotesk(14))
                Spacer()
                Circle()
                    .fill(GS.headlineColor(state.kind))
                    .frame(width: 8, height: 8)
                    .shadow(color: live ? GS.headlineColor(state.kind) : .clear, radius: 4)
                    .widgetAccentable()
                    .accessibilityHidden(true) // the headline says the same
            }

            Spacer(minLength: 4)

            (GS.stateWord(state.kind) + Text("."))
                .font(GS.grotesk(24))
                .tracking(-0.48)
                .foregroundColor(GS.headlineColor(state.kind))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .widgetAccentable()
                .accessibilityLabel(GS.a11yState(state.kind))

            Group {
                if live, let since = state.since {
                    // Timer first: a long relay host is cut at the tail, not it.
                    Text(since, style: .timer) + Text(verbatim: " · ") + GS.route(state.relayHost)
                } else {
                    Text(state.profileName ?? " ")
                }
            }
            .font(GS.mono(10))
            .tracking(1.2)
            .foregroundColor(GS.dim)
            .lineLimit(1)
            .padding(.top, 2)

            Spacer(minLength: 8)

            Group {
                if state.isOn {
                    Button(intent: DisconnectVPNIntent()) { buttonLabel("widget.disconnect") }
                } else {
                    Button(intent: ConnectVPNIntent()) { buttonLabel("widget.connect") }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func buttonLabel(_ key: LocalizedStringKey) -> some View {
        Text(key, tableName: "Widgets")
            .textCase(.uppercase)
            .font(GS.mono(10))
            .tracking(1.6)
            .foregroundColor(GS.bone)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
    }
}
