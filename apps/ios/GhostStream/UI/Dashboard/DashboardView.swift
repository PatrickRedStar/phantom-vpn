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
                    VStack(alignment: .leading, spacing: 16) {
                        nativeStatusCard
                        reconnectBanner
                        emptyHint
                        preflightBanner
                        metricsCard
                        scopeCard
                        muxCard
                        detailsCard
                        NativeBottomAction(
                            title: dashboardPresentation.primaryActionTitle,
                            tone: dashboardPresentation.tone,
                            action: handlePrimaryAction
                        )
                        Spacer(minLength: 88)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
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

    private var dashboardPresentation: DashboardPresentationResult {
        DashboardPresentation.make(
            state: vm.state,
            activeProfileName: profiles.activeProfile?.name,
            timerText: vm.timerText,
            routeIsDirect: routeIsDirect,
            subscriptionText: vm.subscriptionText
        )
    }

    private var nativeStatusCard: some View {
        GhostCard(active: isConnected) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    NativeStatusPill(text: dashboardPresentation.title, tone: dashboardPresentation.tone)
                    Spacer()
                    Text(vm.timerText)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(isConnected ? C.bone : C.textFaint)
                }

                Text(dashboardPresentation.subtitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(C.bone)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text(profiles.activeProfile?.serverAddr ?? "No endpoint selected")
                    .font(.footnote)
                    .foregroundStyle(C.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var metricsCard: some View {
        NativeSectionCard {
            NativeRow(title: "Download", subtitle: rxValueText, action: nil) {
                Text("RX")
                    .foregroundStyle(C.signal)
                    .font(.caption.weight(.bold))
            }
            HairlineDivider()
            NativeRow(title: "Upload", subtitle: txValueText, action: nil) {
                Text("TX")
                    .foregroundStyle(C.warn)
                    .font(.caption.weight(.bold))
            }
        }
    }

    private var detailsCard: some View {
        NativeSectionCard {
            NativeRow(title: "Identity", subtitle: profiles.activeProfile?.name ?? "No profile", action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: "Route", subtitle: dashboardPresentation.routeText, action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: "Assigned address", subtitle: profiles.activeProfile?.tunAddr ?? "—", action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: "Subscription", subtitle: dashboardPresentation.subscriptionText, action: nil) {
                EmptyView()
            }
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

    private var routeIsDirect: Bool {
        guard let profile = profiles.activeProfile else { return true }
        let relayEnabled: Bool = reflectedProfileValue("relayEnabled", in: profile) ?? false
        return !relayEnabled
    }

    private func handlePrimaryAction() {
        switch vm.state {
        case .connected, .connecting, .disconnecting:
            vm.stop()
        case .disconnected, .error:
            vm.start(profile: profiles.activeProfile, preferences: prefs)
        }
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
