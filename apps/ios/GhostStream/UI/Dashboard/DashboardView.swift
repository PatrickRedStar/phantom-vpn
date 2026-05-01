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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectionCard
                reconnectBanner
                emptyHint
                preflightBanner
                scopeCard
                muxCard
                detailsCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(L("nav_stream"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .principal) {
                toolbarMeta
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .onAppear { vm.onAppear() }
    }

    // MARK: - Sections

    private var toolbarMeta: some View {
        HStack(spacing: 6) {
            if shouldPulse(vm.state) {
                Circle()
                    .fill(pulseColor(for: vm.state, colors: C))
                    .frame(width: 6, height: 6)
            }
            Text(headerMetaText)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(C.textDim)
                .lineLimit(1)
        }
    }

    private var bottomActionBar: some View {
        NativeBottomAction(
            title: dashboardPresentation.primaryActionTitle,
            tone: dashboardPresentation.tone,
            action: handlePrimaryAction
        )
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    /// Reconnect banner — visible when `statusFrame.state == .reconnecting`.
    @ViewBuilder
    private var reconnectBanner: some View {
        if stateMgr.statusFrame.state == .reconnecting {
            let attempt = stateMgr.statusFrame.reconnectAttempt.map { Int($0) } ?? 0
            let nextDelay = stateMgr.statusFrame.reconnectNextDelaySecs.map { Int($0) } ?? 0
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("native.dashboard.reconnecting"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.warn)
                    Text(String(format: L("native.dashboard.reconnect.detail.format"), attempt, nextDelay))
                        .font(.footnote)
                        .foregroundStyle(C.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .background(C.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(C.warn.opacity(0.4), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var emptyHint: some View {
        if profiles.activeProfile == nil && !isConnected {
            NativeSectionCard {
                NativeRow(title: L("native.dashboard.add.profile"), subtitle: L("hint_add_profile"), action: nil) {
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
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(C.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("×") {
                    vm.dismissPreflight()
                }
                .foregroundStyle(C.danger)
            }
            .padding(14)
            .background(C.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(C.danger.opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("native.dashboard.traffic"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(C.bone)
                Spacer()
                Button {
                    vm.cycleWindow()
                } label: {
                    Text(vm.window.label)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(C.textDim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(C.bgElev2.opacity(0.8), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }

            ScopeChart(
                rxSamples: vm.rxSamples,
                txSamples: vm.txSamples,
                sampleCapacity: vm.window.rawValue
            )
            .frame(height: 112)
        }
        .padding(16)
        .background(C.bgElev.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(C.hair, lineWidth: 1)
        )
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                NativeStatusPill(text: dashboardPresentation.title, tone: dashboardPresentation.tone)
                Spacer(minLength: 12)
                Text(dashboardPresentation.routeText)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(C.textDim)
                    .lineLimit(1)
            }

            Text(profiles.activeProfile?.serverAddr ?? L("native.dashboard.no.endpoint"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(C.bone)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.top, 16)

            Text(dashboardPresentation.subtitle)
                .font(.footnote)
                .foregroundStyle(C.textDim)
                .lineLimit(2)
                .padding(.top, 4)

            Text(vm.timerText)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isConnected ? C.bone : C.textFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.top, 18)

            HStack(spacing: 10) {
                miniStat(title: L("native.dashboard.download"), value: rxMetricValueText, tint: C.signal)
                miniStat(title: L("native.dashboard.upload"), value: txMetricValueText, tint: C.warn)
            }
            .padding(.top, 18)
        }
        .padding(18)
        .background {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(C.bgElev.opacity(0.96))
                if isConnected {
                    Circle()
                        .fill(C.signal.opacity(0.18))
                        .frame(width: 210, height: 210)
                        .blur(radius: 34)
                        .offset(x: 74, y: -92)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(isConnected ? C.signal.opacity(0.28) : C.hairBold, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 28, x: 0, y: 18)
    }

    private func miniStat(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(C.textFaint)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(C.bg.opacity(0.32), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(C.hair, lineWidth: 1)
        )
    }

    private var muxCard: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("native.dashboard.streams"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(C.bone)
                    Spacer()
                    Text(streamCountText)
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundStyle(streamCountColor)
                }
                MuxBars(
                    active: isConnected,
                    barCount: streamTotalCount,
                    activityLevels: streamActivityForMux
                )
        }
        .padding(16)
        .background(C.bgElev.opacity(0.92), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(C.hair, lineWidth: 1)
        )
    }

    private var streamCountText: String {
        let sf = stateMgr.statusFrame
        guard isConnected else { return L("native.dashboard.streams.empty") }
        let nStreams = sf.nStreams > 0 ? Int(sf.nStreams) : 8
        let streamsUp = Int(sf.streamsUp)
        return String(format: L("native.dashboard.streams.count.format"), streamsUp, nStreams)
    }

    private var rxRateBps: Double {
        let sf = stateMgr.statusFrame
        return sf.rateRxBps > 0 ? sf.rateRxBps : (vm.rxSamples.last ?? 0)
    }

    private var txRateBps: Double {
        let sf = stateMgr.statusFrame
        return sf.rateTxBps > 0 ? sf.rateTxBps : (vm.txSamples.last ?? 0)
    }

    private var rxMetricValueText: String {
        "\(formatMbps(rateBps: rxRateBps)) Mbps"
    }

    private var txMetricValueText: String {
        "\(formatMbps(rateBps: txRateBps)) Mbps"
    }

    private var streamActivityLevels: [Float]? {
        let sf = stateMgr.statusFrame
        let nStreams = sf.nStreams > 0 ? Int(sf.nStreams) : 8
        return isConnected && !sf.streamActivity.isEmpty
            ? Array(sf.streamActivity.prefix(nStreams))
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
        guard isConnected else { return C.textFaint }
        return streamUpCount == streamTotalCount ? C.signal : C.warn
    }

    private var streamActivityForMux: [Float]? {
        streamActivityLevels
    }

    private var dashboardPresentation: DashboardPresentationResult {
        DashboardPresentation.make(
            state: vm.state,
            activeProfileName: profiles.activeProfile?.name,
            timerText: vm.timerText,
            routeIsDirect: routeIsDirect,
            subscriptionText: subscriptionSummaryText
        )
    }

    private var detailsCard: some View {
        NativeSectionCard {
            NativeRow(title: L("kv_identity"), subtitle: profiles.activeProfile?.name ?? L("native.dashboard.no.profile"), action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: L("kv_route"), subtitle: dashboardPresentation.routeText, action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: L("kv_assigned"), subtitle: profiles.activeProfile?.tunAddr ?? "—", action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: L("kv_subscription"), subtitle: dashboardPresentation.subscriptionText, action: nil) {
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
        case .connecting:             return L("native.dashboard.meta.connecting")
        case .disconnecting:          return L("native.dashboard.meta.disconnecting")
        case .error:                  return L("native.dashboard.meta.error")
        case .disconnected:           return L("native.dashboard.meta.standby")
        }
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

    private var subscriptionSummaryText: String? {
        guard let profile = profiles.activeProfile else { return nil }
        return ProfileEntitlementRefresher.subscriptionText(for: profile)
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
