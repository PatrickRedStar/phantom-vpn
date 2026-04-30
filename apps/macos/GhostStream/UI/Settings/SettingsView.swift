//
//  SettingsView.swift
//  GhostStream (macOS)
//
//  SETUP tab — pixel-matched to section 04 of the design HTML.
//
//  Two-column grid (1fr 1fr, 18pt gap) with cards:
//    Left  · "tunnel"          — DNS leak / IPv6 leak / Auto reconnect
//                                / Routing / DNS / Streams.
//    Right · "mac integration" — login item / start in menu bar / show
//                                in Dock / notifications.
//          · "appearance"       — theme / reduce motion.
//          · "updates"          — auto-update / check now button.
//          · "diagnostics"      — export bundle.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct SettingsView: View {

    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs
    @Environment(LoginItemController.self) private var login
    @Environment(DockPolicyController.self) private var dock
    @Environment(UpstreamVpnMonitor.self) private var upstream

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHead
                grid
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
    }

    // MARK: - detail-head

    @ViewBuilder
    private var detailHead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CONFIGURATION")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.20 * 11)
                    .foregroundStyle(C.textFaint)
                HStack(spacing: 0) {
                    Text("setup")
                        .font(.custom("InstrumentSerif-Italic", size: 38))
                        .foregroundStyle(C.signal)
                    Text(".")
                        .font(.custom("SpaceGrotesk-Bold", size: 38))
                        .foregroundStyle(C.textDim)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                Text("BUILD ·")
                    .font(.custom("DepartureMono-Regular", size: 10.5))
                    .tracking(0.16 * 10.5)
                    .foregroundStyle(C.textFaint)
                Text("2026.04.27.0142")
                    .font(.custom("DepartureMono-Regular", size: 10.5))
                    .tracking(0.04 * 10.5)
                    .foregroundStyle(C.bone)
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            DashedHairline()
        }
    }

    // MARK: - 2-column grid

    @ViewBuilder
    private var grid: some View {
        HStack(alignment: .top, spacing: 18) {
            tunnelCard
                .frame(maxWidth: .infinity)
            macColumn
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var tunnelCard: some View {
        @Bindable var p = prefs
        SettingsCard(header: "TUNNEL", trailing: {
            HStack(spacing: 6) {
                PulseDot(color: C.signal, size: 6, pulse: true)
                Text("SAVED")
                    .font(.custom("DepartureMono-Regular", size: 10.5))
                    .tracking(0.12 * 10.5)
                    .foregroundStyle(C.textFaint)
            }
        }) {
            settingRow(title: "DNS leak protection",
                       description: "Принудительно использовать DNS из tunnel profile") {
                SettingsToggle(on: $p.dnsLeakProtection)
            }
            HairlineDivider()
            settingRow(title: "IPv6 leak protection",
                       description: "Отключить IPv6 на интерфейсе пока активен туннель") {
                SettingsToggle(on: $p.ipv6Killswitch)
            }
            HairlineDivider()
            settingRow(title: "Auto reconnect",
                       description: "Восстанавливать туннель при разрывах сети") {
                SettingsToggle(on: $p.autoReconnect)
            }
            HairlineDivider()
            settingRow(title: "Routing",
                       description: "Какой трафик заворачивается в туннель") {
                RoutingPill()
            }
            if p.routingMode == .layeredAuto {
                cardSubHeader("WORK VPN")
                settingRow(title: "Cisco/work VPN first",
                           description: routeDiagnosticText) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(upstream.snapshot.detectedUpstreamCidrs.count)")
                            .font(.custom("DepartureMono-Regular", size: 13))
                            .tracking(0.10 * 13)
                            .foregroundStyle(C.signal)
                        Text("routes")
                            .font(.custom("DepartureMono-Regular", size: 9.5))
                            .tracking(0.14 * 9.5)
                            .foregroundStyle(C.textFaint)
                    }
                }
                HairlineDivider()
                settingRow(title: "Preserve scoped DNS",
                           description: dnsDiagnosticText) {
                    SettingsToggle(on: $p.preserveScopedDns)
                }
                HairlineDivider()
                manualDirectCidrsEditor
            }
            HairlineDivider()
            settingRow(title: "DNS",
                       description: "Custom DNS overrides") {
                DNSPill()
            }
            HairlineDivider()
            settingRow(title: "Streams",
                       description: "Количество H2 streams в туннеле (2…16)") {
                StreamStepper(streams: $p.streams)
            }
        }
    }

    @ViewBuilder
    private var macColumn: some View {
        @Bindable var p = prefs
        VStack(spacing: 0) {
            SettingsCard(header: "MAC INTEGRATION",
                         trailing: { Text("— DARWIN")
                            .font(.custom("DepartureMono-Regular", size: 10.5))
                            .tracking(0.12 * 10.5)
                            .foregroundStyle(C.textFaint) }) {
                @Bindable var loginBinding = login
                @Bindable var dockBinding = dock
                settingRow(title: String(localized: "settings.launch_at_login"),
                           description: "SMAppService.mainApp · login item") {
                    Toggle("", isOn: Binding(
                        get: { loginBinding.enabled },
                        set: { loginBinding.setEnabled($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                HairlineDivider()
                settingRow(title: "Стартовать свернутым в menu bar",
                           description: "Без всплывания консоли · LSUIElement runtime") {
                    SettingsToggle(on: $p.startInMenuBar)
                }
                HairlineDivider()
                settingRow(title: String(localized: "settings.show_in_dock"),
                           description: "Если выключено — app живёт только в menu bar") {
                    Toggle("", isOn: $dockBinding.showInDock)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                HairlineDivider()
                settingRow(title: "Notification на смену состояния",
                           description: "Системный alert при connect/disconnect/reconnect") {
                    SettingsToggle(on: $p.notifyStateChanges)
                }

                cardSubHeader("APPEARANCE")
                settingRow(title: String(localized: "settings.theme"),
                           description: "Тёмная (warm-black + lime), светлая (paper + moss)") {
                    ThemePill()
                }
                HairlineDivider()
                settingRow(title: "Reduce motion",
                           description: "Отключить mux shimmer + pulse") {
                    SettingsToggle(on: $p.reduceMotion)
                }

                cardSubHeader("UPDATES")
                settingRow(title: "Auto-update",
                           description: p.autoUpdate ? "Sparkle не подключен в этой сборке · настройка сохранена" : "Sparkle не подключен в этой сборке") {
                    SettingsToggle(on: $p.autoUpdate)
                }
                HairlineDivider()
                settingRow(title: "Проверить сейчас",
                           description: "Недоступно: Sparkle updater не подключен") {
                    actionButton(label: "ПРОВЕРИТЬ", color: C.signal, disabled: true)
                }

                cardSubHeader("DIAGNOSTICS")
                settingRow(title: "Экспорт bundle",
                           description: "Недоступно: export bundle не реализован в этой сборке") {
                    actionButton(label: "EXPORT", color: C.bone, borderColor: C.hairBold, disabled: true)
                }
            }
        }
    }

    // MARK: - Sub-header inside the right column

    @ViewBuilder
    private func cardSubHeader(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.custom("DepartureMono-Regular", size: 11))
                .tracking(0.18 * 11)
                .foregroundStyle(C.textDim)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(C.bgElev)
        .overlay(alignment: .top) {
            Rectangle().fill(C.hair).frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(C.hair).frame(height: 1)
        }
    }

    @ViewBuilder
    private func settingRow<Trailing: View>(
        title: String,
        description: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.custom("JetBrainsMono-Regular", size: 13))
                    .foregroundStyle(C.bone)
                if let description {
                    Text(description)
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundStyle(C.textFaint)
                        .lineLimit(2)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func actionButton(label: String, color: Color, borderColor: Color? = nil, disabled: Bool = false) -> some View {
        Button { } label: {
            Text(label)
                .font(.custom("DepartureMono-Regular", size: 10.5))
                .tracking(0.16 * 10.5)
                .foregroundStyle(disabled ? C.textFaint : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .overlay(
                    Rectangle().stroke(disabled ? C.hair : (borderColor ?? color), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    @ViewBuilder
    private var manualDirectCidrsEditor: some View {
        @Bindable var p = prefs
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual direct CIDRs")
                        .font(.custom("JetBrainsMono-Regular", size: 13))
                        .foregroundStyle(C.bone)
                    Text("GhostStream bypass · one IPv4 CIDR per line")
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundStyle(C.textFaint)
                }
                Spacer()
                Text("\(prefs.manualDirectCidrs.count)")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.14 * 11)
                    .foregroundStyle(C.signal)
            }

            TextEditor(text: $p.manualDirectCidrsText)
                .font(.custom("JetBrainsMono-Regular", size: 11))
                .foregroundStyle(C.bone)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 74)
                .padding(8)
                .background(C.bgElev2)
                .overlay(Rectangle().stroke(C.hair, lineWidth: 1))

            if !prefs.invalidManualDirectCidrs.isEmpty {
                Text("Invalid: \(prefs.invalidManualDirectCidrs.joined(separator: ", "))")
                    .font(.custom("JetBrainsMono-Regular", size: 10.5))
                    .foregroundStyle(C.danger)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var routeDiagnosticText: String {
        let snapshot = upstream.snapshot
        let provider = snapshot.upstreamProviderName ?? "no upstream VPN detected"
        let interfaces = snapshot.upstreamInterfaceNames.isEmpty
            ? "no utun"
            : snapshot.upstreamInterfaceNames.joined(separator: ", ")
        return "\(provider) · \(interfaces) · hash \(snapshot.routeHash.prefix(8))"
    }

    private var dnsDiagnosticText: String {
        let snapshot = upstream.snapshot
        if snapshot.upstreamDnsDomains.isEmpty && snapshot.upstreamDnsServers.isEmpty {
            return "No upstream scoped DNS detected"
        }
        let domainCount = snapshot.upstreamDnsDomains.count
        let serverCount = snapshot.upstreamDnsServers.count
        return "\(domainCount) domains · \(serverCount) DNS servers stay with work VPN"
    }
}

// MARK: - SettingsCard wrapper

private struct SettingsCard<Header: View, Content: View>: View {
    @Environment(\.gsColors) private var C
    let header: String
    @ViewBuilder var trailing: () -> Header
    @ViewBuilder var content: () -> Content

    init(header: String,
         @ViewBuilder trailing: @escaping () -> Header,
         @ViewBuilder content: @escaping () -> Content) {
        self.header = header
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(header)
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.18 * 11)
                    .foregroundStyle(C.textDim)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(C.bgElev)
            .overlay(alignment: .bottom) {
                Rectangle().fill(C.hair).frame(height: 1)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(C.bgElev)
        }
        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
    }
}

// MARK: - Settings toggle

private struct SettingsToggle: View {
    @Environment(\.gsColors) private var C
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule()
                    .fill(on ? C.signal.opacity(0.18) : C.hair)
                    .frame(width: 36, height: 20)
                    .overlay(
                        Capsule().stroke(on ? C.signal : C.hair, lineWidth: 1)
                    )
                Circle()
                    .fill(on ? C.signal : C.bone)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 2)
            }
            .frame(width: 36, height: 20)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Menu pills

private struct MenuPill: View {
    @Environment(\.gsColors) private var C
    let label: String   // e.g. "all"
    let value: String   // e.g. "global"

    var body: some View {
        HStack(spacing: 6) {
            if !label.isEmpty {
                Text(label)
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.14 * 11)
                    .foregroundStyle(C.bone)
            }
            Text(value)
                .font(.custom("DepartureMono-Regular", size: 11))
                .tracking(0.14 * 11)
                .foregroundStyle(C.signal)
            Text("▾")
                .font(.system(size: 10))
                .foregroundStyle(C.textDim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(C.bgElev2)
        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
    }
}

private struct RoutingPill: View {
    @Environment(PreferencesStore.self) private var prefs

    var body: some View {
        @Bindable var p = prefs
        Menu {
            Button("Global tunnel") { p.routingMode = .global }
            Button("Public split") { p.routingMode = .publicSplit }
            Button("Cisco/work VPN first") { p.routingMode = .layeredAuto }
        } label: {
            MenuPill(
                label: routingLabel(mode: p.routingMode),
                value: routingValue(mode: p.routingMode)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func routingLabel(mode: RoutingMode) -> String {
        switch mode {
        case .global: return "all"
        case .publicSplit: return "split"
        case .layeredAuto: return "work"
        }
    }

    private func routingValue(mode: RoutingMode) -> String {
        switch mode {
        case .global: return "global"
        case .publicSplit: return "public"
        case .layeredAuto: return "first"
        }
    }
}

private struct DNSPill: View {
    @Environment(PreferencesStore.self) private var prefs

    var body: some View {
        @Bindable var p = prefs
        Menu {
            Button("Server push") { p.dnsServers = nil }
            Button("Cloudflare") { p.dnsServers = ["1.1.1.1", "1.0.0.1"] }
            Button("Quad9") { p.dnsServers = ["9.9.9.9", "149.112.112.112"] }
        } label: {
            MenuPill(label: "dns", value: dnsLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var dnsLabel: String {
        guard let dns = prefs.dnsServers, !dns.isEmpty else { return "push" }
        if dns == ["1.1.1.1", "1.0.0.1"] { return "cloudflare" }
        if dns == ["9.9.9.9", "149.112.112.112"] { return "quad9" }
        return "\(dns.count) custom"
    }
}

private struct StreamStepper: View {
    @Environment(\.gsColors) private var C
    @Binding var streams: Int

    var body: some View {
        Stepper(value: $streams, in: 2...16) {
            Text("\(streams)")
                .font(.custom("DepartureMono-Regular", size: 11))
                .tracking(0.14 * 11)
                .foregroundStyle(C.signal)
                .frame(width: 24, alignment: .trailing)
        }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Theme picker pill

private struct ThemePill: View {
    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs

    var body: some View {
        @Bindable var p = prefs
        let cur = ThemeOverride(rawValue: p.theme) ?? .system
        Button {
            // Cycle system → dark → light → system
            switch cur {
            case .system: p.theme = ThemeOverride.dark.rawValue
            case .dark:   p.theme = ThemeOverride.light.rawValue
            case .light:  p.theme = ThemeOverride.system.rawValue
            }
        } label: {
            HStack(spacing: 6) {
                Text(cur.rawValue)
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.14 * 11)
                    .foregroundStyle(C.signal)
                Text("▾")
                    .font(.system(size: 10))
                    .foregroundStyle(C.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(C.bgElev2)
            .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
