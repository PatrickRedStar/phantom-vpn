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

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {

    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs
    @Environment(ProfilesStore.self) private var profiles
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TunnelLogStore.self) private var logStore
    @Environment(LoginItemController.self) private var login
    @Environment(DockPolicyController.self) private var dock
    @Environment(UpstreamVpnMonitor.self) private var upstream

    @State private var exportStatusMessage: String?
    @State private var exportingDiagnostics = false
    @State private var settingsAppeared = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHead
                    .settingsReveal(settingsAppeared, delay: 0.00, reduceMotion: prefs.reduceMotion)
                grid
                    .settingsReveal(settingsAppeared, delay: 0.06, reduceMotion: prefs.reduceMotion)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
        .onAppear {
            SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
                settingsAppeared = true
            }
        }
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
                .settingsReveal(settingsAppeared, delay: 0.10, reduceMotion: prefs.reduceMotion)
            macColumn
                .frame(maxWidth: .infinity)
                .settingsReveal(settingsAppeared, delay: 0.16, reduceMotion: prefs.reduceMotion)
        }
    }

    @ViewBuilder
    private var tunnelCard: some View {
        @Bindable var p = prefs
        SettingsCard(header: "TUNNEL", trailing: {
            HStack(spacing: 6) {
                PulseDot(color: C.signal, size: 6, pulse: !prefs.reduceMotion)
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
                Group {
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
                .transition(SettingsMotion.sectionTransition(reduceMotion: p.reduceMotion))
            }
            HairlineDivider()
            settingRow(title: "DNS",
                       description: "Custom DNS overrides") {
                DNSPill()
            }
            HairlineDivider()
            settingRow(title: "Streams",
                       description: streamDescription) {
                StreamControl(streamOverride: $p.streamOverride)
            }
        }
        .animation(SettingsMotion.layout(reduceMotion: p.reduceMotion), value: p.routingMode)
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
                    SettingsToggle(on: Binding(
                        get: { loginBinding.enabled },
                        set: { loginBinding.setEnabled($0) }
                    ))
                }
                HairlineDivider()
                settingRow(title: "Стартовать свернутым в menu bar",
                           description: "Без всплывания консоли · LSUIElement runtime") {
                    SettingsToggle(on: $p.startInMenuBar)
                }
                HairlineDivider()
                settingRow(title: String(localized: "settings.show_in_dock"),
                           description: "Если выключено — app живёт только в menu bar") {
                    SettingsToggle(on: $dockBinding.showInDock)
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
                           description: "Недоступно: Sparkle updater не подключен") {
                    SettingsToggle(on: .constant(false))
                        .opacity(0.45)
                        .allowsHitTesting(false)
                }
                HairlineDivider()
                settingRow(title: "Проверить сейчас",
                           description: "Недоступно: Sparkle updater не подключен") {
                    actionButton(label: "ПРОВЕРИТЬ", color: C.signal, disabled: true)
                }

                cardSubHeader("DIAGNOSTICS")
                settingRow(title: "Экспорт bundle",
                           description: exportStatusMessage ?? "Snapshot, настройки и последние логи без PEM/conn string") {
                    actionButton(
                        label: exportingDiagnostics ? "EXPORT..." : "EXPORT",
                        color: C.bone,
                        borderColor: C.hairBold,
                        disabled: exportingDiagnostics
                    ) {
                        Task { await exportDiagnostics() }
                    }
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
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        SettingRow(title: title, description: description) {
            trailing()
        }
    }

    @ViewBuilder
    private func actionButton(
        label: String,
        color: Color,
        borderColor: Color? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void = {}
    ) -> some View {
        SettingsActionButton(
            label: label,
            color: color,
            borderColor: borderColor,
            disabled: disabled,
            action: action
        )
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
                    .transition(SettingsMotion.sectionTransition(reduceMotion: prefs.reduceMotion))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .animation(SettingsMotion.layout(reduceMotion: prefs.reduceMotion), value: prefs.invalidManualDirectCidrs)
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

    private var streamDescription: String {
        if let streamOverride = prefs.streamOverride {
            return "Manual override: \(streamOverride) streams, применяется при следующем старте"
        }
        return "Auto: runtime выбирает по CPU; вручную можно поставить 2…16"
    }

    @MainActor
    private func exportDiagnostics() async {
        exportingDiagnostics = true
        defer { exportingDiagnostics = false }

        guard let destination = chooseDiagnosticsBundleURL() else { return }

        do {
            try DiagnosticsBundleExporter.export(
                to: destination,
                preferences: prefs,
                profiles: profiles,
                stateManager: stateMgr,
                logs: logStore
            )
            exportStatusMessage = "Saved: \(destination.lastPathComponent)"
        } catch {
            exportStatusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func chooseDiagnosticsBundleURL() -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultDiagnosticsBundleName()
        if let bundleType = UTType(filenameExtension: "ghoststream-diagnostics") {
            panel.allowedContentTypes = [bundleType]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func defaultDiagnosticsBundleName() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "GhostStream-Diagnostics-\(stamp).ghoststream-diagnostics"
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

// MARK: - Motion

private enum SettingsMotion {
    static func interactive(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.22)
    }

    static func layout(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.28)
    }

    static func reveal(delay: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(0.16, 1.0, 0.30, 1.0, duration: 0.38).delay(delay)
    }

    static func sectionTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .identity
            : .asymmetric(
                insertion: .opacity.combined(with: .move(edge: .top)),
                removal: .opacity
            )
    }

    static func perform(reduceMotion: Bool, _ updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(interactive(reduceMotion: false)) {
                updates()
            }
        }
    }
}

private struct SettingsRevealModifier: ViewModifier {
    let appeared: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: reduceMotion || appeared ? 0 : 10)
            .animation(SettingsMotion.reveal(delay: delay, reduceMotion: reduceMotion), value: appeared)
    }
}

private extension View {
    func settingsReveal(_ appeared: Bool, delay: Double, reduceMotion: Bool) -> some View {
        modifier(SettingsRevealModifier(appeared: appeared, delay: delay, reduceMotion: reduceMotion))
    }
}

// MARK: - Setting row

private struct SettingRow<Trailing: View>: View {
    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs

    let title: String
    let description: String?
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
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
        .background(C.signal.opacity(hovering ? 0.035 : 0))
        .contentShape(Rectangle())
        .opacity(appeared ? 1 : 0)
        .offset(y: prefs.reduceMotion || appeared ? 0 : 6)
        .onHover { isHovering in
            SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
                hovering = isHovering
            }
        }
        .onAppear {
            SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
                appeared = true
            }
        }
        .animation(SettingsMotion.interactive(reduceMotion: prefs.reduceMotion), value: hovering)
    }
}

// MARK: - Settings toggle

private struct SettingsToggle: View {
    @Environment(\.gsColors) private var C
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(PreferencesStore.self) private var prefs

    @Binding var on: Bool
    var disabled = false

    @State private var hovering = false

    var body: some View {
        let reduce = prefs.reduceMotion || systemReduceMotion

        Button {
            guard !disabled else { return }
            SettingsMotion.perform(reduceMotion: reduce) {
                on.toggle()
            }
        } label: {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(on ? C.signal.opacity(hovering ? 0.24 : 0.18) : C.hair)
                    .overlay(Capsule().stroke(borderColor, lineWidth: 1))
                    .shadow(color: C.signal.opacity(on && hovering ? 0.20 : 0), radius: 8, x: 0, y: 0)
                Circle()
                    .fill(on ? C.signal : C.bone)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .stroke(on ? C.bone.opacity(0.22) : C.hairBold, lineWidth: 1)
                    )
                    .shadow(color: on ? C.signal.opacity(0.28) : .clear, radius: 4, x: 0, y: 0)
                    .offset(x: on ? 22 : 2)
            }
            .frame(width: 42, height: 24)
            .scaleEffect(hovering && !disabled ? 1.04 : 1.0)
            .opacity(disabled ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering in
            SettingsMotion.perform(reduceMotion: reduce) {
                hovering = isHovering
            }
        }
        .animation(SettingsMotion.interactive(reduceMotion: reduce), value: on)
        .animation(SettingsMotion.interactive(reduceMotion: reduce), value: hovering)
        .accessibilityLabel(on ? "On" : "Off")
    }

    private var borderColor: Color {
        if disabled { return C.hair }
        if on { return C.signal }
        return hovering ? C.hairBold : C.hair
    }
}

private struct SettingsActionButton: View {
    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs

    let label: String
    let color: Color
    let borderColor: Color?
    let disabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.custom("DepartureMono-Regular", size: 10.5))
                .tracking(0.16 * 10.5)
                .foregroundStyle(disabled ? C.textFaint : color)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(C.signal.opacity(hovering && !disabled ? 0.045 : 0))
                .overlay(
                    Rectangle().stroke(disabled ? C.hair : (borderColor ?? color), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .scaleEffect(hovering && !disabled ? 1.03 : 1.0)
        .onHover { isHovering in
            SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
                hovering = isHovering
            }
        }
        .animation(SettingsMotion.interactive(reduceMotion: prefs.reduceMotion), value: hovering)
    }
}

// MARK: - Menu pills

private struct MenuPill: View {
    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs
    let label: String   // e.g. "all"
    let value: String   // e.g. "global"

    @State private var hovering = false

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
        .background(hovering ? C.signal.opacity(0.045) : C.bgElev2)
        .overlay(Rectangle().stroke(hovering ? C.signalDim : C.hairBold, lineWidth: 1))
        .scaleEffect(hovering ? 1.02 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovering in
            SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
                hovering = isHovering
            }
        }
        .animation(SettingsMotion.interactive(reduceMotion: prefs.reduceMotion), value: hovering)
    }
}

private struct RoutingPill: View {
    @Environment(PreferencesStore.self) private var prefs

    var body: some View {
        @Bindable var p = prefs
        Menu {
            Button("Global tunnel") { setRouting(.global) }
            Button("Public split") { setRouting(.publicSplit) }
            Button("Cisco/work VPN first") { setRouting(.layeredAuto) }
        } label: {
            MenuPill(
                label: routingLabel(mode: p.routingMode),
                value: routingValue(mode: p.routingMode)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setRouting(_ mode: RoutingMode) {
        SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
            prefs.routingMode = mode
        }
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
        Menu {
            Button("Server push") { setDNS(nil) }
            Button("Cloudflare") { setDNS(["1.1.1.1", "1.0.0.1"]) }
            Button("Quad9") { setDNS(["9.9.9.9", "149.112.112.112"]) }
        } label: {
            MenuPill(label: "dns", value: dnsLabel)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func setDNS(_ servers: [String]?) {
        SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
            prefs.dnsServers = servers
        }
    }

    private var dnsLabel: String {
        guard let dns = prefs.dnsServers, !dns.isEmpty else { return "push" }
        if dns == ["1.1.1.1", "1.0.0.1"] { return "cloudflare" }
        if dns == ["9.9.9.9", "149.112.112.112"] { return "quad9" }
        return "\(dns.count) custom"
    }
}

private struct StreamControl: View {
    @Environment(PreferencesStore.self) private var prefs
    @Binding var streamOverride: Int?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Auto") { setStreams(nil) }
                Button("Manual") { setStreams(streamOverride ?? 8) }
                Divider()
                ForEach([2, 4, 8, 12, 16], id: \.self) { value in
                    Button("\(value) streams") { setStreams(value) }
                }
            } label: {
                MenuPill(label: "mux", value: streamOverride.map(String.init) ?? "auto")
            }
            .menuStyle(.borderlessButton)

            if streamOverride != nil {
                Stepper(value: manualValue, in: 2...16) {
                    EmptyView()
                }
                .labelsHidden()
                .controlSize(.small)
                .transition(SettingsMotion.sectionTransition(reduceMotion: prefs.reduceMotion))
            }
        }
        .fixedSize()
        .animation(SettingsMotion.layout(reduceMotion: prefs.reduceMotion), value: streamOverride)
    }

    private var manualValue: Binding<Int> {
        Binding(
            get: { streamOverride ?? 8 },
            set: { setStreams(max(2, min(16, $0))) }
        )
    }

    private func setStreams(_ value: Int?) {
        SettingsMotion.perform(reduceMotion: prefs.reduceMotion) {
            streamOverride = value
        }
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
            SettingsMotion.perform(reduceMotion: p.reduceMotion) {
                // Cycle system → dark → light → system
                switch cur {
                case .system: p.theme = ThemeOverride.dark.rawValue
                case .dark:   p.theme = ThemeOverride.light.rawValue
                case .light:  p.theme = ThemeOverride.system.rawValue
                }
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

@MainActor
private enum DiagnosticsBundleExporter {
    static func export(
        to destination: URL,
        preferences: PreferencesStore,
        profiles: ProfilesStore,
        stateManager: VpnStateManager,
        logs: TunnelLogStore
    ) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let summary = DiagnosticsSummary(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString
        )
        try writeJSON(summary, to: destination.appendingPathComponent("summary.json"))
        try writeJSON(
            DiagnosticsPreferencesSnapshot(preferences: preferences),
            to: destination.appendingPathComponent("preferences.json")
        )
        try writeJSON(
            stateManager.statusFrame,
            to: destination.appendingPathComponent("status-frame.json")
        )
        try writeJSON(
            profiles.profiles.map(DiagnosticsProfileSnapshot.init(profile:)),
            to: destination.appendingPathComponent("profiles.json")
        )
        try writeLogs(
            Array(logs.logs.suffix(2_000)),
            to: destination.appendingPathComponent("logs.jsonl")
        )

        if let snapshotURL = fm
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.vpn")?
            .appendingPathComponent("snapshot.json"),
           fm.fileExists(atPath: snapshotURL.path) {
            try? fm.copyItem(
                at: snapshotURL,
                to: destination.appendingPathComponent("snapshot-file.json")
            )
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func writeLogs(_ frames: [LogFrame], to url: URL) throws {
        let encoder = JSONEncoder()
        let lines = try frames.map { frame in
            let data = try encoder.encode(frame)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        .joined(separator: "\n")
        try (lines + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }
}

private struct DiagnosticsSummary: Codable {
    let generatedAt: String
    let appVersion: String
    let build: String
    let macOS: String
}

private struct DiagnosticsPreferencesSnapshot: Codable {
    let theme: String
    let dnsLeakProtection: Bool
    let ipv6Killswitch: Bool
    let autoReconnect: Bool
    let startInMenuBar: Bool
    let notifyStateChanges: Bool
    let reduceMotion: Bool
    let autoUpdate: Bool
    let streamOverride: Int?
    let routingMode: String
    let dnsServers: [String]?
    let preserveScopedDns: Bool
    let manualDirectCidrs: [String]
    let invalidManualDirectCidrs: [String]

    @MainActor
    init(preferences: PreferencesStore) {
        theme = preferences.theme
        dnsLeakProtection = preferences.dnsLeakProtection
        ipv6Killswitch = preferences.ipv6Killswitch
        autoReconnect = preferences.autoReconnect
        startInMenuBar = preferences.startInMenuBar
        notifyStateChanges = preferences.notifyStateChanges
        reduceMotion = preferences.reduceMotion
        autoUpdate = preferences.autoUpdate
        streamOverride = preferences.streamOverride
        routingMode = preferences.routingMode.rawValue
        dnsServers = preferences.dnsServers
        preserveScopedDns = preferences.preserveScopedDns
        manualDirectCidrs = preferences.manualDirectCidrs
        invalidManualDirectCidrs = preferences.invalidManualDirectCidrs
    }
}

private struct DiagnosticsProfileSnapshot: Codable {
    let id: String
    let name: String
    let serverAddr: String
    let serverName: String
    let insecure: Bool
    let tunAddr: String
    let dnsServers: [String]?
    let splitRouting: Bool?
    let directCountries: [String]?
    let cachedExpiresAt: Int64?
    let cachedEnabled: Bool?
    let cachedIsAdmin: Bool?
    let cachedAdminServerCertFp: String?

    init(profile: VpnProfile) {
        id = profile.id
        name = profile.name
        serverAddr = profile.serverAddr
        serverName = profile.serverName
        insecure = profile.insecure
        tunAddr = profile.tunAddr
        dnsServers = profile.dnsServers
        splitRouting = profile.splitRouting
        directCountries = profile.directCountries
        cachedExpiresAt = profile.cachedExpiresAt
        cachedEnabled = profile.cachedEnabled
        cachedIsAdmin = profile.cachedIsAdmin
        cachedAdminServerCertFp = profile.cachedAdminServerCertFp
    }
}
