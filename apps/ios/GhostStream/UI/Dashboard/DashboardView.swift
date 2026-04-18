//
//  DashboardView.swift
//  GhostStream
//
//  Primary screen: state headline, session timer, scope chart, stat
//  cards, mux bars, connect FAB. Implements §3.1 of the iOS UI spec.
//

import PhantomKit
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

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    stateSection
                    timerRow
                    reconnectBanner
                    emptyHint
                    preflightBanner
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
                    scopeCard
                    statsRow
                    muxCard
                    profileKvCard
                    Spacer(minLength: 120) // bottom nav clearance
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }
        }
        .onAppear { vm.onAppear() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("GHOST//STREAM")
                .gsFont(.brand)
                .foregroundStyle(C.bone)
            Spacer()
            HStack(spacing: 6) {
                Text(headerMetaText)
                    .gsFont(.hdrMeta)
                    .foregroundStyle(C.textFaint)
                PulseDot(
                    color: pulseColor(for: vm.state, colors: C),
                    size: 5,
                    pulse: shouldPulse(vm.state)
                )
            }
        }
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TUNNEL STATE")
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
            Text("SESSION")
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
                Text("NO PROFILE // GO TO SETTINGS")
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

                ScopeChart(rxSamples: vm.rxSamples, txSamples: vm.txSamples)
            }
        }
    }

    private var statsRow: some View {
        // Prefer live rates from statusFrame (pushed by the extension every
        // ~1s); fall back to the VM's computed delta when the frame is stale.
        let sf = stateMgr.statusFrame
        let rxMbps = sf.rateRxBps > 0
            ? formatMbps(rateBps: sf.rateRxBps)
            : formatMbps(rateBps: vm.rxSamples.last ?? 0)
        let txMbps = sf.rateTxBps > 0
            ? formatMbps(rateBps: sf.rateTxBps)
            : formatMbps(rateBps: vm.txSamples.last ?? 0)
        let rxTotal = formatBytesShort(Int64(sf.bytesRx > 0 ? sf.bytesRx : UInt64(vm.samples.last?.bytesRx ?? 0)))
        let txTotal = formatBytesShort(Int64(sf.bytesTx > 0 ? sf.bytesTx : UInt64(vm.samples.last?.bytesTx ?? 0)))
        return HStack(spacing: 10) {
            StatCard(title: "RX", value: rxMbps, unit: "Mbps")
            StatCard(title: "TX", value: txMbps, unit: "Mbps")
            StatCard(title: "RX TOTAL", value: rxTotal.0, unit: rxTotal.1)
            StatCard(title: "TX TOTAL", value: txTotal.0, unit: txTotal.1)
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
                    Text("STREAM MULTIPLEX")
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

    @ViewBuilder
    private var profileKvCard: some View {
        if let p = profiles.activeProfile {
            GhostCard {
                VStack(spacing: 0) {
                    kvRow("IDENTITY",    p.name,    color: C.bone)
                    dashHair
                    kvRow("ASSIGNED",    p.tunAddr, color: C.bone)
                    dashHair
                    kvRow(
                        "SUBSCRIPTION",
                        vm.subscriptionText ?? "—",
                        color: subscriptionColor
                    )
                }
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
        return C.bone
    }

    private func formatMbps(rateBps: Double) -> String {
        // bytes/sec → Mbps = bytes * 8 / 1e6
        let mbps = rateBps * 8.0 / 1_000_000.0
        return String(format: mbps < 10 ? "%.2f" : "%.1f", mbps)
    }

    private func formatBytesShort(_ bytes: Int64) -> (String, String) {
        let b = Double(bytes)
        if b >= 1_000_000_000 { return (String(format: "%.2f", b / 1_000_000_000), "GB") }
        if b >= 1_000_000     { return (String(format: "%.1f", b / 1_000_000),     "MB") }
        if b >= 1_000         { return (String(format: "%.1f", b / 1_000),         "KB") }
        return ("\(bytes)", "B")
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
        case .connected:     return ("", "TRANSMITTING·", C.signal)
        case .connecting:    return ("", "TUNING···",      C.warn)
        case .disconnecting: return ("", "CLOSING···",     C.warn)
        case .error:         return ("LOST ", "SIGNAL·",   C.danger)
        case .disconnected:  return ("", "STANDBY·",       C.textDim)
        }
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
