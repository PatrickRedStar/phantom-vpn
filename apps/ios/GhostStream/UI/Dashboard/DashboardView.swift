//
//  DashboardView.swift
//  GhostStream
//
//  «Поток»: brand + profile chip + profile switch, state headline and
//  session timer, traffic/mux card, KV card. The primary action floats
//  above the tab bar as tinted glass.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Root Dashboard screen. Consumes the main-actor singletons via the
/// environment and owns a private `DashboardViewModel` for the polling
/// state.
struct DashboardView: View {

    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles
    @Environment(PreferencesStore.self) private var prefs
    @Environment(VpnStateManager.self) private var stateMgr

    @State private var vm = DashboardViewModel()

    /// Opens the add-profile flow (Settings tab).
    private let onAddProfile: () -> Void

    init(onAddProfile: @escaping () -> Void = {}) {
        self.onAddProfile = onAddProfile
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                stateBlock
                reconnectBanner
                healthBanner
                emptyHint
                preflightBanner
                trafficCard
                detailsCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .scrollIndicators(.hidden)
        .background(C.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .task { await vm.run() }
        .task(id: isConnected) {
            if isConnected { await vm.refreshEntitlements() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            (Text("G").foregroundColor(C.signal) + Text("hoststream").foregroundColor(C.bone))
                .gsFont(.brand)
            Spacer(minLength: 8)
            if let profile = profiles.activeProfile {
                HStack(spacing: 8) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 7, height: 7)
                        .shadow(color: stateColor, radius: 4)
                    Text(profile.name.uppercased())
                        .gsFont(.hdrMeta)
                        .foregroundStyle(C.bone)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassBackground(Capsule())
            }
            if profiles.profiles.count > 1 {
                profileMenu
            }
        }
        .frame(minHeight: 44)
    }

    private var profileMenu: some View {
        Menu {
            ForEach(profiles.profiles) { profile in
                Button {
                    // Switching while connected reconnects to the new profile.
                    SettingsViewModel().setActiveProfile(id: profile.id)
                } label: {
                    if profile.id == profiles.activeId {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(C.bone)
                .frame(width: 36, height: 36)
                .glassBackground(Circle())
        }
        .accessibilityLabel(L("dashboard.switch.profile"))
    }

    // MARK: - State

    private var stateBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("lbl_tunnel_state").uppercased())
                .gsFont(.labelMono)
                .foregroundStyle(C.textDim)
            (Text(dashboardPresentation.title).foregroundColor(stateColor) + Text(".").foregroundColor(C.bone))
                .gsFont(.stateHeadline)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            if case .error(let reason) = vm.state {
                Text(reason)
                    .font(.custom(GsFontName.jetBrainsMono, size: 12))
                    .foregroundStyle(C.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(vm.timerText)
                    .gsFont(.ticker)
                    .foregroundStyle(isUp ? C.bone : C.textFaint)
                Spacer()
                Text(L(isReconnecting ? "lbl_session_ongoing" : "lbl_session").uppercased())
                    .gsFont(.labelMono)
                    .foregroundStyle(C.textDim)
            }
        }
        .padding(.top, 10)
    }

    private var bottomActionBar: some View {
        GlassPrimaryButton(
            title: dashboardPresentation.primaryActionTitle,
            systemImage: "power",
            tint: primaryTint,
            prominent: !isTransitioning,
            action: handlePrimaryAction
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private var primaryTint: Color {
        dashboardPresentation.tone == .danger ? C.danger : C.signal
    }

    // MARK: - Banners

    /// Reconnect banner — the core is retrying (ADR 0018), session survives.
    @ViewBuilder
    private var reconnectBanner: some View {
        if isReconnecting {
            let sf = stateMgr.statusFrame
            banner(
                icon: "arrow.clockwise",
                title: L("native.dashboard.reconnect.title"),
                detail: String(
                    format: L("native.dashboard.reconnect.detail.format"),
                    Int(sf.reconnectAttempt ?? 0),
                    Int(sf.reconnectNextDelaySecs ?? 0)
                ),
                color: C.warn
            )
        }
    }

    /// Health banner — the tunnel is up, but the core reports dead streams,
    /// silence or throttling (same states the Android dashboard shows).
    @ViewBuilder
    private var healthBanner: some View {
        if let text = healthWarningText {
            banner(icon: "exclamationmark.triangle", title: text, detail: nil, color: C.warn)
        }
    }

    private var healthWarningText: String? {
        let sf = stateMgr.statusFrame
        guard sf.state == .connected else { return nil }
        switch sf.health {
        case .dead?:
            return L("native.dashboard.health.dead")
        case .degraded?:
            // The core reports throttling as `degraded` too.
            if sf.bandwidthClass == .throttled {
                return L("native.dashboard.health.throttled")
            }
            return String(format: L("native.dashboard.health.degraded.format"), Int(sf.streamsUp), Int(sf.nStreams))
        case .stale?:
            return String(format: L("native.dashboard.health.stale.format"), Int(sf.idleRxSecs ?? 0))
        default:
            return nil
        }
    }

    private func banner(icon: String, title: String, detail: String?, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.custom(GsFontName.spaceGroteskBold, size: 15))
                    .foregroundStyle(C.bone)
                if let detail {
                    Text(detail)
                        .font(.custom(GsFontName.jetBrainsMono, size: 11))
                        .foregroundStyle(C.textDim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(color.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var emptyHint: some View {
        if profiles.activeProfile == nil && !isUp {
            NativeSectionCard {
                NativeRow(title: L("native.dashboard.add.profile"), subtitle: L("hint_add_profile"), action: onAddProfile) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(C.signal)
                }
            }
        }
    }

    @ViewBuilder
    private var preflightBanner: some View {
        if let warn = vm.preflightWarning {
            HStack(spacing: 10) {
                Text(warn)
                    .font(.custom(GsFontName.jetBrainsMono, size: 12))
                    .foregroundStyle(C.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    vm.dismissPreflight()
                } label: {
                    Image(systemName: "xmark")
                }
                .foregroundStyle(C.danger)
            }
            .padding(14)
            .background(C.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(C.danger.opacity(0.4), lineWidth: 1)
            )
        }
    }

    // MARK: - Traffic + mux

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isReconnecting {
                HStack {
                    HStack(spacing: 14) {
                        legend(color: C.signal, text: "RX \(rate(rxRateBps))")
                        legend(color: C.warn, text: "TX \(rate(txRateBps))")
                    }
                    Spacer()
                    Button {
                        vm.cycleWindow()
                    } label: {
                        Text(vm.window.label.uppercased())
                            .gsFont(.hdrMeta)
                            .foregroundStyle(C.textDim)
                    }
                    .buttonStyle(.plain)
                }
                ScopeChart(
                    rxSamples: vm.rxSamples,
                    txSamples: vm.txSamples,
                    sampleCapacity: vm.window.rawValue
                )
                .frame(height: 92)
                HairlineDivider()
            }
            HStack {
                Text(L("lbl_stream_multiplex").uppercased())
                    .gsFont(.labelMono)
                    .foregroundStyle(C.textDim)
                Spacer()
                Text(streamCountText)
                    .gsFont(.labelMono)
                    .foregroundStyle(streamCountColor)
            }
            MuxBars(
                active: isUp,
                barCount: streamTotalCount,
                activityLevels: streamActivityLevels,
                height: 34
            )
            if isReconnecting {
                Text(L("native.dashboard.reconnect.caption"))
                    .font(.custom(GsFontName.jetBrainsMono, size: 11))
                    .foregroundStyle(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .gsCardBackground(C)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 12, height: 2)
            Text(text)
                .font(.custom(GsFontName.jetBrainsMono, size: 11))
                .foregroundStyle(C.textDim)
                .monospacedDigit()
        }
    }

    // MARK: - Details

    private var detailsCard: some View {
        let profile = profiles.activeProfile
        return VStack(spacing: 0) {
            if !isReconnecting {
                kvRow(L("settings.row.dns"), dnsText, valueColor: C.bone, dot: isUp)
                HairlineDivider()
                kvRow(L("kv_identity"), profile?.name ?? "—")
                HairlineDivider()
            }
            kvRow(L("kv_route"), routeText, valueColor: isUp ? C.signal : C.bone)
            if !isReconnecting {
                HairlineDivider()
                kvRow(L("kv_assigned"), profile?.tunAddr ?? "—")
                HairlineDivider()
                kvRow(L("kv_subscription"), subscriptionValue)
            }
            if isUp, let mib = stateMgr.tunnelMemoryMiB {
                HairlineDivider()
                kvRow(
                    L("kv_tunnel_memory"),
                    String(format: L("kv_tunnel_memory.format"), locale: .current, mib),
                    valueColor: mib > 40 ? C.warn : C.bone
                )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .gsCardBackground(C)
    }

    private func kvRow(_ label: String, _ value: String, valueColor: Color? = nil, dot: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label.uppercased())
                .gsFont(.labelMono)
                .foregroundStyle(C.textDim)
            Spacer(minLength: 12)
            if dot {
                Circle().fill(C.signal).frame(width: 6, height: 6)
            }
            Text(value)
                .font(.custom(GsFontName.jetBrainsMono, size: 11))
                .foregroundStyle(valueColor ?? C.bone)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Derived

    private var dnsText: String {
        let servers = prefs.dnsServers ?? profiles.activeProfile?.dnsServers ?? ["1.1.1.1", "8.8.8.8"]
        return servers.joined(separator: " · ")
    }

    private var routeText: String {
        guard let profile = profiles.activeProfile else { return "—" }
        return profile.relayActive
            ? "\(L("kv_route_relay")) · \(profile.effectiveServerAddr)"
            : "\(L("kv_route_direct")) · \(profile.serverAddr)"
    }

    private var subscriptionValue: String {
        guard let profile = profiles.activeProfile else { return "—" }
        if profile.cachedEnabled != false, let expiresAt = profile.cachedExpiresAt {
            let remaining = expiresAt - Int64(Date().timeIntervalSince1970)
            if remaining > 0 {
                return String(format: L("kv_subscription.dh.format"), remaining / 86_400, (remaining % 86_400) / 3_600)
            }
        }
        return ProfileEntitlementRefresher.subscriptionText(for: profile) ?? "—"
    }

    private var streamCountText: String {
        guard isUp else { return L("native.dashboard.streams.empty") }
        return "\(streamUpCount) / \(streamTotalCount)"
    }

    private var rxRateBps: Double {
        let sf = stateMgr.statusFrame
        return sf.rateRxBps > 0 ? sf.rateRxBps : (vm.rxSamples.last ?? 0)
    }

    private var txRateBps: Double {
        let sf = stateMgr.statusFrame
        return sf.rateTxBps > 0 ? sf.rateTxBps : (vm.txSamples.last ?? 0)
    }

    /// StatusFrame bits/s → «2,41 МБ/с».
    private func rate(_ bps: Double) -> String {
        String(format: L("dashboard.rate.mbs.format"), locale: .current,
               DashboardPresentation.megabytesPerSecond(bitsPerSecond: bps))
    }

    private var streamActivityLevels: [Float]? {
        let sf = stateMgr.statusFrame
        return isUp && !sf.streamActivity.isEmpty
            ? Array(sf.streamActivity.prefix(streamTotalCount))
            : nil
    }

    private var streamTotalCount: Int {
        let sf = stateMgr.statusFrame
        return sf.nStreams > 0 ? Int(sf.nStreams) : 8
    }

    private var streamUpCount: Int {
        Int(stateMgr.statusFrame.streamsUp)
    }

    private var streamCountColor: Color {
        guard isUp else { return C.textFaint }
        return streamUpCount == streamTotalCount ? C.signal : C.warn
    }

    private var dashboardPresentation: DashboardPresentationResult {
        DashboardPresentation.make(
            state: vm.state,
            activeProfileName: profiles.activeProfile?.name,
            timerText: vm.timerText,
            routeIsDirect: profiles.activeProfile?.relayActive != true,
            subscriptionText: nil
        )
    }

    private var stateColor: Color {
        pulseColor(for: vm.state, colors: C)
    }

    private var isUp: Bool {
        switch vm.state {
        case .connected, .reconnecting: return true
        default: return false
        }
    }

    private var isConnected: Bool {
        if case .connected = vm.state { return true }
        return false
    }

    private var isReconnecting: Bool {
        if case .reconnecting = vm.state { return true }
        return false
    }

    private var isTransitioning: Bool {
        switch vm.state {
        case .connecting, .reconnecting, .disconnecting: return true
        default: return false
        }
    }

    private func handlePrimaryAction() {
        switch vm.state {
        case .connected, .connecting, .reconnecting, .disconnecting:
            vm.stop()
        case .disconnected, .error:
            vm.start(profile: profiles.activeProfile, preferences: prefs)
        }
    }

    private func L(_ key: String) -> String {
        AppStrings.localized(key)
    }
}

// MARK: - Preview

#Preview("Dashboard — Disconnected") {
    NavigationStack { DashboardView() }
        .environment(ProfilesStore.shared)
        .environment(PreferencesStore.shared)
        .environment(VpnStateManager.shared)
        .gsTheme(override: .dark)
}

#Preview("Dashboard — Connected") {
    let _ = VpnStateManager.shared.update(
        .connected(since: Date().addingTimeInterval(-1234), serverName: "nl")
    )
    return NavigationStack { DashboardView() }
        .environment(ProfilesStore.shared)
        .environment(PreferencesStore.shared)
        .environment(VpnStateManager.shared)
        .gsTheme(override: .dark)
}
