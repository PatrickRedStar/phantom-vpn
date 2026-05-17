//
//  DashboardView.swift
//  GhostStream (macOS)
//
//  STREAM tab — pixel-matched to section 02 of the design HTML.
//
//  Vertical layout:
//    1. detail-head: lblmono "tunnel state" + 54pt state hero (left) /
//       pulse + "session" lbl + ticker 26pt timer (right).
//    2. endpoint row: 4 KV labels (endpoint / sni / tun ip / disconnect
//       ghost-fab on the right).
//    3. card "scope · throughput": 240pt scope chart + window-pill.
//    4. bottom row: 360pt mux card (left) + 4-cell KV grid (right).
//

import PhantomKit
import PhantomUI
import SwiftUI
import os.log

private let dashLog = Logger(subsystem: "com.ghoststream.client", category: "DashboardView")

public struct DashboardView: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TrafficSeriesStore.self) private var traffic
    @Environment(ProfilesStore.self) private var profiles
    @Environment(PreferencesStore.self) private var prefs
    @Environment(SystemExtensionInstaller.self) private var sysExt
    @Environment(DockPolicyController.self) private var dock
    @EnvironmentObject private var tunnel: VpnTunnelController

    @State private var scopeWindow: ScopeWindow = .m5
    // UI-R2-R03/R04: Track whether we transitioned through `.connected`
    // since the last error. Round 1's UI-H3 fix cleared `lastError` on
    // every `.disconnected` arrival — but the natural failure flow is
    // `.connecting → .error → .disconnected`, which means the error
    // text vanished ~100ms after surfacing. We now only clear on the
    // benign path: user explicitly disconnected from `.connected`.
    @State private var wasConnected = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                detailHead
                endpointRow
                scopeCard
                bottomRow
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
        .task { traffic.start(stateManager: stateMgr) }
        // UI-R2-R03/R04 (was UI-H3): clear the inline error chip only
        // when the tunnel transitioned through a successful
        // `.connected` state and is now `.disconnected`. The previous
        // implementation cleared on any `.disconnected` arrival, which
        // wiped errors raised on the failure path
        // `.connecting → .error → .disconnected` before the user could
        // read them.
        .onChange(of: stateMgr.statusFrame.state) { _, newState in
            if newState == .connected {
                wasConnected = true
            } else if newState == .disconnected && wasConnected {
                Task { @MainActor in tunnel.lastError = nil }
                wasConnected = false
            }
        }
    }

    // MARK: - 1. detail-head

    @ViewBuilder
    private var detailHead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TUNNEL STATE")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.20 * 11)
                    .foregroundStyle(C.textFaint)
                stateHero
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                HStack(spacing: 6) {
                    PulseDot(
                        color: pulseColor,
                        size: 8,
                        pulse: !prefs.reduceMotion && (stateMgr.statusFrame.state == .connected
                            || stateMgr.statusFrame.state == .connecting
                            || stateMgr.statusFrame.state == .reconnecting)
                    )
                    Text("SESSION")
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .tracking(0.16 * 10.5)
                        .foregroundStyle(C.textDim)
                }
                Text(timerText)
                    .font(.custom("DepartureMono-Regular", size: 26))
                    .tracking(0.04 * 26)
                    .foregroundStyle(stateMgr.statusFrame.state == .connected ? C.bone : C.textFaint)
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            DashedHairline()
        }
    }

    @ViewBuilder
    private var stateHero: some View {
        let (verb, accent) = heroParts
        HStack(spacing: 0) {
            Text(verb)
                .font(.custom("InstrumentSerif-Italic", size: 54))
                .foregroundStyle(accent)
            Text(".")
                .font(.custom("SpaceGrotesk-Bold", size: 54))
                .foregroundStyle(accent)
        }
        .lineLimit(1)
    }

    private var heroParts: (String, Color) {
        switch stateMgr.statusFrame.state {
        case .disconnected:               return ("standby",     C.textDim)
        case .connecting:                 return ("tuning",      C.warn)
        case .reconnecting:               return ("regrouping",  C.warn)
        case .connected:                  return ("transmitting", C.signal)
        case .error:                      return ("lost signal", C.danger)
        }
    }

    private var pulseColor: Color {
        switch stateMgr.statusFrame.state {
        case .connected:                  return C.signal
        case .connecting, .reconnecting:  return C.warn
        case .error:                      return C.danger
        case .disconnected:               return C.textFaint
        }
    }

    private var timerText: String {
        let secs = stateMgr.statusFrame.sessionSecs
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if stateMgr.statusFrame.state == .connected {
            return String(format: "%02d:%02d:%02d", h, m, s)
        }
        return "—:—:—"
    }

    private var tunAddrText: String {
        guard stateMgr.statusFrame.state == .connected else { return "—" }
        guard let raw = stateMgr.statusFrame.tunAddr?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "—"
        }

        let cidrParts = raw.split(separator: "/", maxSplits: 1)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        if cidrParts.count == 2, !cidrParts[0].isEmpty, !cidrParts[1].isEmpty {
            return "\(cidrParts[0]) / \(cidrParts[1])"
        }
        return raw
    }

    // MARK: - 2. endpoint row

    @ViewBuilder
    private var endpointRow: some View {
        // UI-R2-N20: during `connecting`/`reconnecting` the button now
        // surfaces CANCEL instead of being disabled. The Round 1 UI-H1
        // fix gated parallel `installAndStart` calls by disabling the
        // button — but that left the user with no escape during the
        // 75s TLS deadline on slow servers. CANCEL is a `tunnel.stop()`
        // call, idempotent if a teardown is already in flight.
        let state = stateMgr.statusFrame.state
        let live = state == .connected
        let busy = state == .connecting || state == .reconnecting
        let buttonTint: Color = busy ? C.warn : (live ? C.danger : C.signal)
        let buttonLabel: String = busy
            ? "CANCEL"
            : (live ? "DISCONNECT" : "CONNECT")
        HStack(alignment: .bottom, spacing: 24) {
            kvLabel(label: "ENDPOINT") {
                if let host = profiles.activeProfile?.serverAddr, !host.isEmpty {
                    let parts = host.split(separator: ":", maxSplits: 1).map(String.init)
                    HStack(spacing: 0) {
                        Text(parts.first ?? host)
                            .font(.custom("JetBrainsMono-Regular", size: 14))
                            .foregroundStyle(C.signal)
                        if parts.count > 1 {
                            Text(":")
                                .font(.custom("JetBrainsMono-Regular", size: 14))
                                .foregroundStyle(C.bone)
                            Text(parts[1])
                                .font(.custom("JetBrainsMono-Regular", size: 14))
                                .foregroundStyle(C.signal)
                        }
                    }
                    // UI-H4: clamp the line + middle-truncate when
                    // the endpoint is a long DNS name or IPv6 — it
                    // used to push the CONNECT button off-screen.
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(host)
                } else {
                    Text("—")
                        .font(.custom("JetBrainsMono-Regular", size: 14))
                        .foregroundStyle(C.textFaint)
                }
            }

            kvLabel(label: "SNI") {
                Text(profiles.activeProfile?.serverName ?? "—")
                    .font(.custom("JetBrainsMono-Regular", size: 14))
                    .foregroundStyle(C.bone)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(profiles.activeProfile?.serverName ?? "")
            }

            kvLabel(label: "TUN IP") {
                Text(tunAddrText)
                    .font(.custom("JetBrainsMono-Regular", size: 14))
                    .foregroundStyle(C.bone)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(tunAddrText)
            }

            Spacer()

            // Connect / disconnect / cancel compact GhostFab
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    dashLog.info("Connect button tapped — live=\(live, privacy: .public) busy=\(busy, privacy: .public)")
                    Task { await toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(buttonLabel)
                            .font(.custom("DepartureMono-Regular", size: 11))
                            .tracking(0.20 * 11)
                        if busy {
                            // Keep the spinner during busy so the user
                            // gets visual confirmation a teardown is
                            // in progress when CANCEL is tapped.
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            KeyboardShortcutHint("⌘K")
                        }
                    }
                    .foregroundStyle(buttonTint)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .overlay(
                        Rectangle().stroke(buttonTint, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)
                // UI-R2-N20: button never goes disabled — CANCEL is a
                // valid action during busy states. The Round 1 race on
                // parallel `installAndStart` is still prevented by the
                // `live || busy → stop()` branch in `toggle()`.

                if let err = inlineConnectError {
                    Text(err)
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundStyle(C.danger)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
        }
    }

    private var inlineConnectError: String? {
        if let msg = tunnel.lastError, !msg.isEmpty { return msg }
        return nil
    }

    @ViewBuilder
    private func kvLabel<V: View>(
        label: String,
        @ViewBuilder content: () -> V
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.custom("DepartureMono-Regular", size: 10.5))
                .tracking(0.18 * 10.5)
                .foregroundStyle(C.textFaint)
            content()
        }
    }

    // MARK: - 3. scope card

    @ViewBuilder
    private var scopeCard: some View {
        let series = traffic.series(capacity: scopeWindow.rawValue)
        let chartRxSamples = isSamplingState ? series.rxSamples : []
        let chartTxSamples = isSamplingState ? series.txSamples : []

        VStack(spacing: 0) {
            // card header
            HStack {
                Text("SCOPE · THROUGHPUT")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.18 * 11)
                    .foregroundStyle(C.textDim)
                Spacer()
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle().fill(C.signal).frame(width: 6, height: 6)
                        Text("RX")
                            .font(.custom("DepartureMono-Regular", size: 10.5))
                            .tracking(0.12 * 10.5)
                            .foregroundStyle(C.textDim)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(C.warn).frame(width: 6, height: 6)
                        Text("TX")
                            .font(.custom("DepartureMono-Regular", size: 10.5))
                            .tracking(0.12 * 10.5)
                            .foregroundStyle(C.textDim)
                    }
                    Text("WINDOW")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .tracking(0.12 * 10)
                        .foregroundStyle(C.textFaint)
                        .padding(.leading, 6)
                    Menu {
                        ForEach(ScopeWindow.allCases, id: \.self) { option in
                            Button(option.label) {
                                scopeWindow = option
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text(scopeWindow.label)
                                .font(.custom("DepartureMono-Regular", size: 10.5))
                                .foregroundStyle(C.signal)
                            Text("▾").foregroundStyle(C.signal).font(.system(size: 9))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(C.bgElev)
            .overlay(alignment: .bottom) {
                Rectangle().fill(C.hair).frame(height: 1)
            }

            // scope canvas
            ZStack(alignment: .topLeading) {
                ScopeChart(
                    rxSamples: chartRxSamples,
                    txSamples: chartTxSamples,
                    height: 240,
                    sampleCapacity: series.sampleCapacity
                )
                // tag row TL
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(C.signal).frame(width: 6, height: 6)
                        Text("RX \(formatRate(displayRxRateBps))")
                            .font(.custom("DepartureMono-Regular", size: 9.5))
                            .tracking(0.16 * 9.5)
                            .foregroundStyle(C.textFaint)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(C.warn).frame(width: 6, height: 6)
                        Text("TX \(formatRate(displayTxRateBps))")
                            .font(.custom("DepartureMono-Regular", size: 9.5))
                            .tracking(0.16 * 9.5)
                            .foregroundStyle(C.textFaint)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                // Window pill TR
                VStack {
                    HStack {
                        Spacer()
                        Text(scopeWindow.label.uppercased())
                            .font(.custom("DepartureMono-Regular", size: 9.5))
                            .tracking(0.16 * 9.5)
                            .foregroundStyle(C.bone)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(C.bg.opacity(0.75))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(C.hairBold, lineWidth: 1)
                            )
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
            .frame(height: 240)
            .background(C.bgElev2)
        }
        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
    }

    // MARK: - 4. bottom row

    @ViewBuilder
    private var bottomRow: some View {
        HStack(alignment: .top, spacing: 18) {
            muxCard
                .frame(width: 360)
            kvGrid
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var muxCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MUX · STREAMS")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.18 * 11)
                    .foregroundStyle(C.textDim)
                Spacer()
                HStack(spacing: 6) {
                    PulseDot(
                        color: pulseColor,
                        size: 6,
                        pulse: !prefs.reduceMotion && stateMgr.statusFrame.state == .connected
                    )
                    Text("\(stateMgr.statusFrame.streamsUp) ↑ \(stateMgr.statusFrame.nStreams)")
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .tracking(0.12 * 10.5)
                        .foregroundStyle(C.textFaint)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(C.bgElev)
            .overlay(alignment: .bottom) {
                Rectangle().fill(C.hair).frame(height: 1)
            }

            // Per ADR 0007 the runtime is the only source of truth for
            // `nStreams`. The UI follows whatever the runtime reports,
            // clamped to [1, 16] so the widget never collapses.
            let bars = TelemetryDisplayHelpers.barCountFromStreams(stateMgr.statusFrame.nStreams)
            VStack(spacing: 10) {
                MuxBars(
                    active: stateMgr.statusFrame.state == .connected,
                    barCount: bars,
                    activityLevels: stateMgr.statusFrame.streamActivity,
                    reduceMotion: prefs.reduceMotion,
                    height: 84
                )
                HStack {
                    ForEach(1...bars, id: \.self) { idx in
                        Text(String(format: "S%02d", idx))
                            .font(.custom("DepartureMono-Regular", size: 9.5))
                            .tracking(0.18 * 9.5)
                            .foregroundStyle(C.textFaint)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .background(C.bgElev)
        }
        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
    }

    @ViewBuilder
    private var kvGrid: some View {
        let frame = stateMgr.statusFrame
        let active = frame.state == .connected
        HStack(spacing: 0) {
            kvCell(label: "RX · RATE",
                   value: active ? splitRate(displayRxRateBps).val : "—",
                   unit:  active ? splitRate(displayRxRateBps).unit : "",
                   highlight: true)
            kvDivider
            kvCell(label: "TX · RATE",
                   value: active ? splitRate(displayTxRateBps).val : "—",
                   unit:  active ? splitRate(displayTxRateBps).unit : "",
                   highlight: false)
            kvDivider
            kvCell(label: "RTT",
                   value: frame.rttMs.map { "\($0)" } ?? "—",
                   unit:  frame.rttMs != nil ? "MS" : "",
                   highlight: false)
            kvDivider
            kvCell(label: "TOTAL RX",
                   value: active ? splitBytes(totalRxBytes).val : "—",
                   unit:  active ? splitBytes(totalRxBytes).unit : "",
                   highlight: false)
        }
        .background(C.bgElev2)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
    }

    @ViewBuilder
    private func kvCell(label: String, value: String, unit: String, highlight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.custom("DepartureMono-Regular", size: 10))
                .tracking(0.18 * 10)
                .foregroundStyle(C.textFaint)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.custom("SpaceGrotesk-Bold", size: 24))
                    .tracking(-0.01 * 24)
                    .foregroundStyle(highlight ? C.signal : C.bone)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .tracking(0.08 * 10.5)
                        .foregroundStyle(C.textDim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }

    private var kvDivider: some View {
        Rectangle()
            .fill(C.hair)
            .frame(width: 1)
    }

    // MARK: - Helpers

    private func toggle() async {
        let state = stateMgr.statusFrame.state
        // UI-R2-N20: connected → DISCONNECT, busy → CANCEL. Both paths
        // funnel to `tunnel.stop()` so a half-completed handshake can be
        // torn down before it hits the 75s TLS deadline.
        if state == .connected || state == .connecting || state == .reconnecting {
            dashLog.info("toggle → stop (state=\(String(describing: state), privacy: .public))")
            tunnel.stop()
            return
        }
        if let preflightError = connectPreflightError() {
            dashLog.info("toggle → prerequisites missing, opening Welcome wizard")
            tunnel.lastError = preflightError
            openForegroundWindow("welcome")
            return
        }
        guard let profile = profiles.activeProfile else { return }
        dashLog.info("toggle → installAndStart profile=\(profile.id, privacy: .public)")
        do {
            try await tunnel.installAndStart(profile: profile, preferences: PreferencesStore.shared)
            tunnel.lastError = nil
        } catch {
            dashLog.error("installAndStart failed: \(error.localizedDescription, privacy: .public)")
            tunnel.lastError = error.localizedDescription
        }
    }

    private func openForegroundWindow(_ id: String) {
        openWindow(id: id)
        dock.activateForegroundWindow()
    }

    private func connectPreflightError() -> String? {
        if profiles.activeProfile == nil {
            return "No VPN profile selected. Opening setup to import one."
        }

        switch sysExt.state {
        case .activated:
            return nil
        case .failed(let message):
            return "System extension is not ready: \(message). Opening setup."
        case .awaitingUserApproval:
            return "System extension is waiting for approval. Opening setup."
        case .requestPending:
            return "System extension install is still pending. Opening setup."
        case .notInstalled:
            return "System extension is not installed yet. Opening setup."
        }
    }

    private var isSamplingState: Bool {
        stateMgr.statusFrame.state == .connected
            || stateMgr.statusFrame.state == .connecting
            || stateMgr.statusFrame.state == .reconnecting
    }

    private var totalRxBytes: UInt64 {
        let bytes = stateMgr.statusFrame.bytesRx
        if bytes > 0 { return bytes }
        return traffic.currentRxBytes
    }

    /// Throughput exposed to the UI is bytes/sec. The wire contract of
    /// `StatusFrame.rate_rx_bps` is bits/sec, so the fallback path divides
    /// by 8. `TrafficSeriesStore.currentRxRateBps` is already bytes/sec.
    private var displayRxRateBps: Double {
        if traffic.currentRxRateBps > 0 { return traffic.currentRxRateBps }
        return TelemetryDisplayHelpers
            .bytesPerSecondFromBitsPerSecond(stateMgr.statusFrame.rateRxBps)
    }

    private var displayTxRateBps: Double {
        if traffic.currentTxRateBps > 0 { return traffic.currentTxRateBps }
        return TelemetryDisplayHelpers
            .bytesPerSecondFromBitsPerSecond(stateMgr.statusFrame.rateTxBps)
    }

    private func formatRate(_ bps: Double) -> String {
        let kb = bps / 1024.0
        if kb < 1024 { return String(format: "%.1f KB/S", kb) }
        return String(format: "%.2f MB/S", kb / 1024.0)
    }

    private func splitRate(_ bps: Double) -> (val: String, unit: String) {
        let kb = bps / 1024.0
        if kb < 1024 {
            return (String(format: "%.0f", kb), "KB/S")
        }
        return (String(format: "%.2f", kb / 1024.0), "MB/S")
    }

    private func splitBytes(_ bytes: UInt64) -> (val: String, unit: String) {
        let kb = Double(bytes) / 1024.0
        if kb < 1024 {
            return (String(format: "%.0f", kb), "KB")
        }
        let mb = kb / 1024.0
        if mb < 1024 {
            return (String(format: "%.2f", mb), "MB")
        }
        return (String(format: "%.2f", mb / 1024.0), "GB")
    }
}

// MARK: - DashedHairline

/// Dashed equivalent of `HairlineDivider` — used by `detail-head` borders
/// in section 02..05 of the design HTML.
struct DashedHairline: View {
    @Environment(\.gsColors) private var C
    var body: some View {
        Rectangle()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(C.hairBold)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
