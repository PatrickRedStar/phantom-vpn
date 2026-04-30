//
//  MenuBarPopover.swift
//  GhostStream (macOS)
//
//  Primary surface — 380×520 popover content. Pixel-matched to section 01
//  of the rustling-foraging-wadler-design.html spec.
//
//  Layout breakdown (top→bottom):
//    1. Header  — 18×14pt padding, ScopeRingGlyph 18pt + brand text
//                 (Space Grotesk Bold 13.5pt) + pulse-pill on the right
//                 (mono 9.5pt 0.16em uppercase, hairBold border, 3pt radius).
//    2. Hairline divider.
//    3. Body    — 22pt horizontal, 24pt top, 16pt bottom padding.
//                 a. lblmono "tunnel state" 10pt 0.20em.
//                 b. State hero 38pt Space Grotesk Bold -0.025em with
//                    serif-italic verb. Coloured per state.
//                 c. Timer 22pt Departure Mono 0.04em.
//                 d. Big GhostFab (idle outline / live solid danger).
//                 e. Profile pill — hairlines top+bottom, 14pt vertical,
//                    [PROF lbl][nm 14pt + endpoint 11pt][rtt 10.5pt][chev].
//                 f. Mini scope chart 64pt high, info-pill TL, rate TR.
//                 g. Mux row — "MUX · 3↑8" lbl + 28pt MuxBars on the right.
//    4. Hairline divider.
//    5. Footer  — kbd shortcut rows (⌘0 console, ⌘⇧C palette, ⌘Q quit).
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI
import os.log

private let popoverLog = Logger(subsystem: "com.ghoststream.vpn", category: "MenuBarPopover")

public struct MenuBarPopover: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow

    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(ProfilesStore.self) private var profiles
    @Environment(SystemExtensionInstaller.self) private var sysExt
    @Environment(AppRouter.self) private var router
    @EnvironmentObject private var tunnel: VpnTunnelController

    @State private var miniRxHistory: [Double] = []
    @State private var miniTxHistory: [Double] = []

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HairlineDivider()
            body_
            Spacer(minLength: 0)
            HairlineDivider()
            footer
        }
        .frame(width: 380, height: 520, alignment: .top)
        .background(C.bg)
        .onAppear { pushMiniSampleIfLive() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            pushMiniSampleIfLive()
        }
    }

    // MARK: - Header (1)

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            ScopeRingGlyph(size: 18, signal: brandRingSignal, dim: C.signalDim)
            Text("GhostStream")
                .font(.custom("SpaceGrotesk-Bold", size: 13.5))
                .tracking(-0.01 * 13.5)
                .foregroundStyle(C.bone)
            Spacer()
            statusPill
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    /// Brand ring colour — full signal when live, faint warm-grey when idle
    /// (mirrors the dual-svg variant in the HTML preview).
    private var brandRingSignal: Color {
        switch stateMgr.statusFrame.state {
        case .connected:                  return C.signal
        case .connecting, .reconnecting:  return C.warn
        case .error:                      return C.danger
        case .disconnected:               return C.textFaint
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let isLive = stateMgr.statusFrame.state == .connected
        let isWarn = stateMgr.statusFrame.state == .connecting
                  || stateMgr.statusFrame.state == .reconnecting
        let isErr  = stateMgr.statusFrame.state == .error
        let label = pillLabel
        let color: Color = isLive ? C.signal
                          : (isWarn ? C.warn
                          : (isErr ? C.danger : C.textFaint))
        let pulses = isLive || isWarn

        HStack(spacing: 7) {
            PulseDot(color: color, size: 6, pulse: pulses)
            Text(label)
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.16 * 9.5)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(isLive ? C.signal.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(isLive ? C.signalDim : C.hairBold, lineWidth: 1)
        )
    }

    private var pillLabel: String {
        switch stateMgr.statusFrame.state {
        case .disconnected:  return "STANDBY"
        case .connecting:    return "TUNING"
        case .reconnecting:  return "REGROUPING"
        case .connected:     return "TRANSMITTING"
        case .error:         return "LOST"
        }
    }

    // MARK: - Body (3)

    @ViewBuilder
    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tunnel-state label
            Text("TUNNEL STATE")
                .font(.custom("DepartureMono-Regular", size: 10))
                .tracking(0.20 * 10)
                .foregroundStyle(C.textFaint)
                .padding(.bottom, 12)

            // Hero state headline
            stateHero
                .padding(.bottom, 14)

            // Session timer
            Text(timerText)
                .font(.custom("DepartureMono-Regular", size: 22))
                .tracking(0.04 * 22)
                .foregroundStyle(stateMgr.statusFrame.state == .connected ? C.bone : C.textFaint)
                .padding(.bottom, 18)

            // GhostFab connect / disconnect
            fabRow
                .padding(.bottom, 14)

            // Profile pill — hairlines top + bottom
            profileBlock

            // Conditional content depending on state
            if stateMgr.statusFrame.state == .connected {
                miniScope
                    .padding(.bottom, 14)
                muxRow
            } else {
                Text("NO ACTIVE TUNNEL")
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.18 * 10)
                    .foregroundStyle(C.textFaint)
                    .padding(.vertical, 6)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var stateHero: some View {
        // 38pt Space Grotesk Bold -0.025em + serif italic verb + dot
        let (verb, accent) = heroParts
        HStack(spacing: 0) {
            Text(verb)
                .font(.custom("InstrumentSerif-Italic", size: 38))
                .foregroundStyle(accent)
            Text(".")
                .font(.custom("SpaceGrotesk-Bold", size: 38))
                .foregroundStyle(accent)
        }
        .lineLimit(1)
    }

    private var heroParts: (verb: String, accent: Color) {
        switch stateMgr.statusFrame.state {
        case .disconnected:               return ("standby",     C.textDim)
        case .connecting:                 return ("tuning",      C.warn)
        case .reconnecting:               return ("regrouping",  C.warn)
        case .connected:                  return ("transmitting", C.signal)
        case .error:                      return ("lost signal", C.danger)
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

    @ViewBuilder
    private var fabRow: some View {
        let live = stateMgr.statusFrame.state == .connected
        VStack(alignment: .leading, spacing: 8) {
            GhostFab(
                text: live ? "DISCONNECT" : "CONNECT",
                outline: !live,
                tint: live ? C.danger : C.signal
            ) {
                popoverLog.info("GhostFab tapped — live=\(live, privacy: .public)")
                Task { await toggleConnect() }
            }
            if let err = inlineConnectError {
                Text(err)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .foregroundStyle(C.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Surface only real connection failures inline. Missing prerequisites
    /// (no profile, sys-ext not activated) are now handled by the wizard,
    /// which gets opened from `toggleConnect()` instead of being shown as
    /// a red inline message.
    private var inlineConnectError: String? {
        if let msg = tunnel.lastError, !msg.isEmpty { return msg }
        return nil
    }

    @ViewBuilder
    private var profileBlock: some View {
        VStack(spacing: 0) {
            HairlineDivider()
            HStack(spacing: 14) {
                Text("PROF")
                    .font(.custom("DepartureMono-Regular", size: 9.5))
                    .tracking(0.18 * 9.5)
                    .foregroundStyle(C.textFaint)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(profiles.activeProfile?.name ?? "—")
                        .font(.custom("SpaceGrotesk-Bold", size: 14))
                        .tracking(-0.01 * 14)
                        .foregroundStyle(C.bone)
                    if let endpoint = profileEndpoint {
                        Text(endpoint)
                            .font(.custom("JetBrainsMono-Regular", size: 11))
                            .foregroundStyle(C.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Text(rttLabel)
                    .font(.custom("DepartureMono-Regular", size: 10.5))
                    .tracking(0.06 * 10.5)
                    .foregroundStyle(stateMgr.statusFrame.rttMs != nil ? C.signal : C.textFaint)

                Image(systemName: "chevron.up.chevron.down")
                    .foregroundStyle(C.textDim)
                    .font(.system(size: 10))
            }
            .padding(.vertical, 14)
            HairlineDivider()
        }
        .padding(.bottom, 14)
    }

    private var profileEndpoint: String? {
        guard let host = profiles.activeProfile?.serverAddr, !host.isEmpty else { return nil }
        return host
    }

    private var rttLabel: String {
        if let rtt = stateMgr.statusFrame.rttMs { return "\(rtt)ms" }
        return "— ms"
    }

    // MARK: - Mini scope (transmitting only)

    @ViewBuilder
    private var miniScope: some View {
        ZStack(alignment: .topLeading) {
            ScopeChart(
                rxSamples: stateMgr.statusFrame.state == .connected ? miniRxHistory : [],
                txSamples: stateMgr.statusFrame.state == .connected ? miniTxHistory : [],
                height: 64
            )
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(C.signal).frame(width: 6, height: 6)
                        Text("RX · 60S")
                            .font(.custom("DepartureMono-Regular", size: 9))
                            .tracking(0.16 * 9)
                            .foregroundStyle(C.textFaint)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(C.warn).frame(width: 6, height: 6)
                        Text("TX · 60S")
                            .font(.custom("DepartureMono-Regular", size: 9))
                            .tracking(0.16 * 9)
                            .foregroundStyle(C.textFaint)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(formatRate(stateMgr.statusFrame.rateRxBps))
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .foregroundStyle(C.bone)
                    Text(formatRate(stateMgr.statusFrame.rateTxBps))
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .foregroundStyle(C.textDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        .frame(height: 64)
        .background(C.bgElev2)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
    }

    @ViewBuilder
    private var muxRow: some View {
        HStack(spacing: 14) {
            Text("MUX · \(stateMgr.statusFrame.streamsUp)↑\(stateMgr.statusFrame.nStreams)")
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.18 * 9.5)
                .foregroundStyle(C.textFaint)
            MuxBars(
                active: stateMgr.statusFrame.state == .connected,
                barCount: 8,
                activityLevels: stateMgr.statusFrame.streamActivity,
                height: 28
            )
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            HairlineDivider()
        }
    }

    // MARK: - Footer (5)

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 0) {
            footerRow(
                systemImage: "rectangle.on.rectangle",
                title: String(localized: "menu.open_console"),
                kbd: "⌘0",
                color: C.bone
            ) {
                openWindow(id: "console")
                NSApp.activate(ignoringOtherApps: true)
            }
            footerRow(
                systemImage: "command",
                title: String(localized: "menu.command_palette"),
                kbd: "⌘⇧C",
                color: C.bone
            ) {
                openWindow(id: "console")
                NSApp.activate(ignoringOtherApps: true)
                router.commandPaletteOpen = true
            }
            footerRow(
                systemImage: stateMgr.statusFrame.state == .connected ? "clock" : "power",
                title: stateMgr.statusFrame.state == .connected ? "Логи" : String(localized: "menu.quit"),
                kbd: stateMgr.statusFrame.state == .connected ? "⌘⇧L" : "⌘Q",
                color: stateMgr.statusFrame.state == .connected ? C.bone : C.danger
            ) {
                if stateMgr.statusFrame.state == .connected {
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                } else {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func footerRow(
        systemImage: String,
        title: String,
        kbd: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .foregroundStyle(C.textDim)
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.custom("JetBrainsMono-Regular", size: 13))
                    .foregroundStyle(color)
                Spacer()
                KeyboardShortcutHint(kbd)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func toggleConnect() async {
        let isLive = stateMgr.statusFrame.state == .connected
        if isLive {
            popoverLog.info("toggleConnect → stop")
            tunnel.stop()
            return
        }

        // Any prerequisite missing → punt the user to the wizard. We do
        // NOT surface red inline errors for these cases; the onboarding
        // window has full explanations and System Settings deeplinks.
        if profiles.activeProfile == nil
            || sysExt.state != .activated {
            popoverLog.info("toggleConnect → prerequisites missing, opening Welcome wizard")
            tunnel.lastError = nil
            openWindow(id: "welcome")
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let profile = profiles.activeProfile else { return }
        popoverLog.info("toggleConnect → installAndStart profile=\(profile.id, privacy: .public)")
        do {
            try await tunnel.installAndStart(profile: profile, preferences: PreferencesStore.shared)
            tunnel.lastError = nil
        } catch {
            popoverLog.error("installAndStart failed: \(error.localizedDescription, privacy: .public)")
            tunnel.lastError = error.localizedDescription
        }
    }

    private func formatRate(_ bps: Double) -> String {
        let kb = bps / 1024.0
        if kb < 1024 {
            return String(format: "%.2f KB/S", kb)
        }
        return String(format: "%.2f MB/S", kb / 1024.0)
    }

    private func pushMiniSampleIfLive() {
        let state = stateMgr.statusFrame.state
        guard state == .connected || state == .connecting else { return }
        miniRxHistory.append(stateMgr.statusFrame.rateRxBps)
        miniTxHistory.append(stateMgr.statusFrame.rateTxBps)
        trimMiniHistory()
    }

    private func trimMiniHistory() {
        let cap = 60
        if miniRxHistory.count > cap { miniRxHistory.removeFirst(miniRxHistory.count - cap) }
        if miniTxHistory.count > cap { miniTxHistory.removeFirst(miniTxHistory.count - cap) }
    }
}

// MARK: - Phosphor scope ring glyph (used in popover header / brand)

struct ScopeRingGlyph: View {
    let size: CGFloat
    let signal: Color
    let dim: Color

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            // outer ring
            ctx.stroke(
                Path { p in
                    p.addArc(center: center, radius: r * 0.92, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                },
                with: .color(signal.opacity(0.75)),
                lineWidth: 1.5
            )
            // dashed inner
            ctx.stroke(
                Path { p in
                    p.addArc(center: center, radius: r * 0.55, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                },
                with: .color(signal.opacity(0.4)),
                style: StrokeStyle(lineWidth: 1, dash: [2, 3])
            )
            // sine trace
            var path = Path()
            let steps = 24
            let amp = r * 0.35
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let x = (center.x - r) + r * 2 * t
                let y = center.y - sin(t * .pi * 4) * amp * 0.6
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            ctx.stroke(path, with: .color(signal), lineWidth: 1.5)
            // center dot
            ctx.fill(
                Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                with: .color(signal)
            )
        }
        .frame(width: size, height: size)
    }
}
