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

private let dashLog = Logger(subsystem: "com.ghoststream.vpn", category: "DashboardView")

public struct DashboardView: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(ProfilesStore.self) private var profiles
    @Environment(SystemExtensionInstaller.self) private var sysExt
    @EnvironmentObject private var tunnel: VpnTunnelController

    @State private var scopeWindow: ScopeWindow = .m5
    @State private var rxHistory: [Double] = []
    @State private var txHistory: [Double] = []
    @State private var lastRxBytes: UInt64 = 0

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
        .onAppear { pushSampleIfLive() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            pushSampleIfLive()
        }
        .onChange(of: scopeWindow) { _, _ in trimHistory() }
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
                        pulse: stateMgr.statusFrame.state == .connected
                            || stateMgr.statusFrame.state == .connecting
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
            }

            kvLabel(label: "TUN IP") {
                Text(tunAddrText)
                    .font(.custom("JetBrainsMono-Regular", size: 14))
                    .foregroundStyle(C.bone)
            }

            Spacer()

            // Connect / disconnect compact GhostFab
            let live = stateMgr.statusFrame.state == .connected
            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    dashLog.info("Connect button tapped — live=\(live, privacy: .public)")
                    Task { await toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Text(live ? "DISCONNECT" : "CONNECT")
                            .font(.custom("DepartureMono-Regular", size: 11))
                            .tracking(0.20 * 11)
                        KeyboardShortcutHint("⌘K")
                    }
                    .foregroundStyle(live ? C.danger : C.signal)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .overlay(
                        Rectangle().stroke(live ? C.danger : C.signal, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: .command)

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
                    Button {
                        scopeWindow = scopeWindow.next
                    } label: {
                        HStack(spacing: 2) {
                            Text(scopeWindow.label)
                                .font(.custom("DepartureMono-Regular", size: 10.5))
                                .foregroundStyle(C.signal)
                            Text("▾").foregroundStyle(C.signal).font(.system(size: 9))
                        }
                    }
                    .buttonStyle(.plain)
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
                    rxSamples: rxHistory,
                    txSamples: txHistory,
                    height: 240
                )
                // tag row TL
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().fill(C.signal).frame(width: 6, height: 6)
                        Text("RX \(formatRate(stateMgr.statusFrame.rateRxBps))")
                            .font(.custom("DepartureMono-Regular", size: 9.5))
                            .tracking(0.16 * 9.5)
                            .foregroundStyle(C.textFaint)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(C.warn).frame(width: 6, height: 6)
                        Text("TX \(formatRate(stateMgr.statusFrame.rateTxBps))")
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
                    PulseDot(color: pulseColor, size: 6, pulse: stateMgr.statusFrame.state == .connected)
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

            VStack(spacing: 10) {
                MuxBars(
                    active: stateMgr.statusFrame.state == .connected,
                    barCount: 8,
                    activityLevels: stateMgr.statusFrame.streamActivity,
                    height: 84
                )
                HStack {
                    ForEach(1...8, id: \.self) { idx in
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
                   value: active ? splitRate(frame.rateRxBps).val : "—",
                   unit:  active ? splitRate(frame.rateRxBps).unit : "",
                   highlight: true)
            kvDivider
            kvCell(label: "TX · RATE",
                   value: active ? splitRate(frame.rateTxBps).val : "—",
                   unit:  active ? splitRate(frame.rateTxBps).unit : "",
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
        if stateMgr.statusFrame.state == .connected {
            dashLog.info("toggle → stop")
            tunnel.stop()
            return
        }
        // Missing profile or sys-ext not activated → open the wizard.
        if profiles.activeProfile == nil || sysExt.state != .activated {
            dashLog.info("toggle → prerequisites missing, opening Welcome wizard")
            tunnel.lastError = nil
            openWindow(id: "welcome")
            NSApp.activate(ignoringOtherApps: true)
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

    private var isSamplingState: Bool {
        stateMgr.statusFrame.state == .connected || stateMgr.statusFrame.state == .connecting
    }

    private var totalRxBytes: UInt64 {
        let bytes = stateMgr.statusFrame.bytesRx
        if bytes > 0 { return bytes }
        return lastRxBytes
    }

    private func pushSampleIfLive() {
        guard isSamplingState else { return }
        pushSample()
    }

    private func pushSample() {
        let cap = scopeWindow.rawValue
        rxHistory.append(stateMgr.statusFrame.rateRxBps)
        txHistory.append(stateMgr.statusFrame.rateTxBps)
        lastRxBytes = max(lastRxBytes, stateMgr.statusFrame.bytesRx)
        trimHistory(cap: cap)
    }

    private func trimHistory(cap: Int? = nil) {
        let cap = cap ?? scopeWindow.rawValue
        if rxHistory.count > cap { rxHistory.removeFirst(rxHistory.count - cap) }
        if txHistory.count > cap { txHistory.removeFirst(txHistory.count - cap) }
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
