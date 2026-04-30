//
//  DashboardView.swift
//  GhostStream
//
//  Primary screen: state headline, session timer, scope chart, stat
//  cards, mux bars, connect FAB. Implements §3.1 of the iOS UI spec.
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

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        stateSection
                        timerRow
                        reconnectBanner
                        emptyHint
                        preflightBanner
                        scopeCard
                        muxCard
                        profileKvCard
                        VpnConnectFab(
                            state: vm.state,
                            onStart: {
                                vm.start(
                                    profile: profiles.activeProfile,
                                    preferences: prefs
                                )
                            },
                            onStop: vm.stop
                        )
                        Spacer(minLength: 120) // bottom nav clearance
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 16)
                }
            }
        }
        .onAppear { vm.onAppear() }
    }

    // MARK: - Sections

    private var header: some View {
        ScreenHeader(
            brand: NSLocalizedString("brand_stream", comment: ""),
            meta: headerMetaText,
            pulse: shouldPulse(vm.state),
            pulseColor: pulseColor(for: vm.state, colors: C)
        )
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("lbl_tunnel_state").uppercased())
                .gsFont(.labelMono)
                .foregroundStyle(C.textFaint)

            let (prefix, accent, accentColor) = stateHeadline(for: vm.state, C: C)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(prefix)
                    .gsFont(.stateHeadline)
                    .foregroundStyle(C.bone)
                Text(accent)
                    .gsFont(.stateHeadline)
                    .foregroundStyle(accentColor)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .animation(.easeInOut(duration: 0.22), value: stateKey(vm.state))
        }
    }

    private var timerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(vm.timerText)
                .gsFont(.ticker)
                .foregroundStyle(isConnected ? C.bone : C.textFaint)
            Spacer()
            Text(L("lbl_session").uppercased())
                .gsFont(.labelMonoSmall)
                .foregroundStyle(C.textFaint)
        }
    }

    /// Reconnect banner — visible when `statusFrame.state == .reconnecting`.
    @ViewBuilder
    private var reconnectBanner: some View {
        if stateMgr.statusFrame.state == .reconnecting {
            let attempt = stateMgr.statusFrame.reconnectAttempt.map { Int($0) } ?? 0
            let nextDelay = stateMgr.statusFrame.reconnectNextDelaySecs.map { Int($0) } ?? 0
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RECONNECTING")
                        .gsFont(.labelMono)
                        .foregroundStyle(C.warn)
                    Text("Попытка \(attempt) · след. через \(nextDelay)с")
                        .gsFont(.kvValue)
                        .foregroundStyle(C.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(C.warn.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(C.warn.opacity(0.4), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if profiles.activeProfile == nil && !isConnected {
            GhostCard {
                Text(L("hint_add_profile").uppercased())
                    .gsFont(.body)
                    .foregroundStyle(C.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var preflightBanner: some View {
        if let warn = vm.preflightWarning {
            HStack(spacing: 10) {
                Text(warn)
                    .gsFont(.kvValue)
                    .foregroundStyle(C.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("×") {
                    vm.dismissPreflight()
                }
                .foregroundStyle(C.danger)
            }
            .padding(12)
            .background(C.danger.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(C.danger.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var scopeCard: some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(C.signal)
                            .frame(width: 2, height: 14)
                        Text(rxValueText)
                            .gsFont(.kvValue)
                            .foregroundStyle(C.bone)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(C.warn)
                            .frame(width: 2, height: 14)
                        Text(txValueText)
                            .gsFont(.kvValue)
                            .foregroundStyle(C.bone)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 8)
                    Button {
                        vm.cycleWindow()
                    } label: {
                        Text("\(vm.window.label)")
                            .gsFont(.hdrMeta)
                            .foregroundStyle(C.textFaint)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                }

                Divider().background(C.hair).frame(height: 1)

                ScopeChart(
                    rxSamples: vm.rxSamples,
                    txSamples: vm.txSamples,
                    sampleCapacity: vm.window.rawValue
                )
            }
        }
    }

    private var muxCard: some View {
        let sf = stateMgr.statusFrame
        // Use real stream counts when available; fall back to defaults.
        let nStreams = sf.nStreams > 0 ? Int(sf.nStreams) : 8
        let streamsUp = Int(sf.streamsUp)
        let streamCountText = isConnected
            ? "\(streamsUp)/\(nStreams) STREAMS"
            : "—/— STREAMS"
        let streamCountColor: Color = isConnected
            ? (streamsUp == nStreams ? C.signal : C.warn)
            : C.textFaint
        // Pass real activity levels when connected; nil → synthetic shimmer.
        let activityLevels: [Float]? = isConnected && !sf.streamActivity.isEmpty
            ? Array(sf.streamActivity.prefix(nStreams))
            : nil
        return GhostCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("lbl_stream_multiplex").uppercased())
                        .gsFont(.hdrMeta)
                        .foregroundStyle(C.textDim)
                    Spacer()
                    Text(streamCountText)
                        .gsFont(.hdrMeta)
                        .foregroundStyle(streamCountColor)
                }
                Divider().background(C.hair).frame(height: 1)
                MuxBars(
                    active: isConnected,
                    barCount: nStreams,
                    activityLevels: activityLevels
                )
            }
        }
    }

    private var profileKvCard: some View {
        let route = routeInfo(for: profiles.activeProfile)
        return GhostCard {
            VStack(spacing: 0) {
                kvRow(L("kv_identity").uppercased(), profiles.activeProfile?.name ?? "—", color: C.bone)
                dashHair
                kvRow(L("kv_route").uppercased(), route.value, color: route.color)
                dashHair
                kvRow(L("kv_assigned").uppercased(), profiles.activeProfile?.tunAddr ?? "—", color: C.bone)
                dashHair
                kvRow(
                    L("kv_subscription").uppercased(),
                    vm.subscriptionText ?? "—",
                    color: subscriptionColor
                )
            }
        }
    }

    private var dashHair: some View {
        // Poor-man's dashed hairline: dot-pattern overlay.
        Rectangle()
            .fill(C.hair)
            .frame(height: 1)
            .mask(
                HStack(spacing: 4) {
                    ForEach(0..<60, id: \.self) { _ in
                        Rectangle().frame(width: 4, height: 1)
                    }
                }
            )
            .padding(.vertical, 6)
    }

    private func kvRow(_ label: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .gsFont(.labelMono)
                .foregroundStyle(C.textFaint)
            Spacer()
            Text(value)
                .gsFont(.kvValue)
                .foregroundStyle(color)
        }
    }

    // MARK: - Derived strings

    private var isConnected: Bool {
        if case .connected = vm.state { return true }
        return false
    }

    private var headerMetaText: String {
        switch vm.state {
        case .connected(_, let name): return "\(name) · \(vm.timerText)"
        case .connecting:             return "connecting"
        case .disconnecting:          return "disconnecting"
        case .error:                  return "error"
        case .disconnected:           return "standby"
        }
    }

    private var rxValueText: String {
        let sf = stateMgr.statusFrame
        let bps = sf.rateRxBps > 0 ? sf.rateRxBps : (vm.rxSamples.last ?? 0)
        return "RX \(formatMbps(rateBps: bps))"
    }

    private var txValueText: String {
        let sf = stateMgr.statusFrame
        let bps = sf.rateTxBps > 0 ? sf.rateTxBps : (vm.txSamples.last ?? 0)
        return "TX \(formatMbps(rateBps: bps))"
    }

    private var subscriptionColor: Color {
        guard let text = vm.subscriptionText else { return C.bone }
        if text.contains("истекл") { return C.danger }
        return C.signal
    }

    private func formatMbps(rateBps: Double) -> String {
        // bytes/sec → Mbps = bytes * 8 / 1e6
        let mbps = rateBps * 8.0 / 1_000_000.0
        return String(format: mbps < 10 ? "%.2f" : "%.1f", mbps)
    }

    private func shouldPulse(_ state: VpnState) -> Bool {
        switch state {
        case .connected, .connecting, .disconnecting: return true
        default: return false
        }
    }

    /// Cheap equality key for AnimatedContent-style transitions.
    private func stateKey(_ s: VpnState) -> Int {
        switch s {
        case .disconnected:  return 0
        case .connecting:    return 1
        case .connected:     return 2
        case .disconnecting: return 3
        case .error:         return 4
        }
    }

    /// Headline text split into (prefix in bone, accent word, accent
    /// colour) matching the spec copy.
    private func stateHeadline(
        for state: VpnState,
        C: GsColorSet
    ) -> (String, String, Color) {
        switch state {
        case .connected:
            return ("", "\(L("state_transmitting_verb").uppercased())·", C.signal)
        case .connecting, .disconnecting:
            return ("", "\(L("state_tuning_verb").uppercased())···", C.warn)
        case .error:
            return ("", "\(L("state_lost_verb").uppercased()) \(L("state_signal_word").uppercased())·", C.danger)
        case .disconnected:
            return ("", "\(L("state_standby_verb").uppercased())·", C.textDim)
        }
    }

    private func routeInfo(for profile: VpnProfile?) -> (value: String, color: Color) {
        guard let profile else { return (L("kv_route_direct").lowercased(), C.bone) }
        let relayEnabled: Bool = reflectedProfileValue("relayEnabled", in: profile) ?? false
        guard relayEnabled else { return (L("kv_route_direct").lowercased(), C.bone) }

        let relayAddr: String? = reflectedProfileValue("relayAddr", in: profile)
        if let relayAddr, !relayAddr.isEmpty {
            return ("\(L("kv_route_relay").lowercased()) · \(relayAddr)", C.signal)
        }
        return (L("kv_route_relay").lowercased(), C.signal)
    }

    private func reflectedProfileValue<T>(_ label: String, in profile: VpnProfile) -> T? {
        for child in Mirror(reflecting: profile).children where child.label == label {
            if let value = child.value as? T { return value }
            let mirror = Mirror(reflecting: child.value)
            if mirror.displayStyle == .optional,
               let value = mirror.children.first?.value as? T {
                return value
            }
        }
        return nil
    }

    private func L(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
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
