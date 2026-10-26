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

private let popoverLog = Logger(subsystem: "com.ghoststream.client", category: "MenuBarPopover")

public struct MenuBarPopover: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow

    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TrafficSeriesStore.self) private var traffic
    @Environment(ProfilesStore.self) private var profiles
    @Environment(PreferencesStore.self) private var prefs
    @Environment(SystemExtensionInstaller.self) private var sysExt
    @Environment(AppRouter.self) private var router
    @Environment(DockPolicyController.self) private var dock
    @EnvironmentObject private var tunnel: VpnTunnelController

    // A3: системный Reduce Motion должен гейтить анимации наравне с
    // ручным тумблером — эффективный флаг = OR обоих источников.
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { prefs.reduceMotion || systemReduceMotion }

    // A4: строка «Вставить конфиг» в футере появляется только когда в
    // буфере лежит ghs:// — детектим в onAppear попапа. `pasteStatus`
    // держит локальную ошибку импорта (danger, 5с TTL).
    @State private var clipboardConfig: String?
    @State private var pasteStatus: String?
    @State private var pasteStatusTask: Task<Void, Never>?

    // UI-R2-R03/R04 / UI-R4-R06: track whether we transitioned through
    // `.connected` since the last error in the Service layer
    // (`tunnel.hadSuccessfulConnect`) rather than per-view. The Round 2
    // implementation used `@State wasConnected` on both this view and
    // the dashboard — they could disagree after a channel switch,
    // leaving stale `lastError` text on screen across surfaces.

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
        // UI-POPOVER-CLIP fix (июль 2026, round 2): высота СТАТИЧНАЯ и
        // рассчитана на самый высокий (connected) макет. Первый подход
        // с minHeight не сработал: MenuBarExtra(.window) фиксирует
        // размер окна при первом показе и НЕ ресайзит его по intrinsic
        // size контента — попап, впервые открытый в standby (520),
        // навсегда обрезал connected-контент. Одна высота на все
        // состояния = ресайз не нужен вовсе; в standby Spacer
        // растягивает пустую зону между контентом и футером.
        .frame(width: 380, height: 600, alignment: .top)
        .background(C.bg)
        .task { traffic.start(stateManager: stateMgr) }
        // A4: пересчитываем наличие ghs:// в буфере при каждом показе
        // попапа (MenuBarExtra(.window) переинициализирует контент).
        .onAppear { refreshClipboardConfig() }
        // UI-R2-R03/R04 / UI-R4-R06: forward state transitions into the
        // shared `tunnel.observeStateForSuccessTracking(_:)` so all
        // surfaces (popover, dashboard) agree on the
        // `hadSuccessfulConnect` flag. Errors raised on the failure
        // path (`.connecting → .error → .disconnected`) survive until
        // the next live session; benign disconnects clear cleanly.
        .onChange(of: stateMgr.statusFrame.state) { _, newState in
            tunnel.observeStateForSuccessTracking(newState)
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
            PulseDot(color: color, size: 6, pulse: !reduceMotion && pulses)
            Text(label)
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.16 * 9.5)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: GsRadius.chip, style: .continuous)
                .fill(isLive ? C.signal.opacity(0.05) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GsRadius.chip, style: .continuous)
                .stroke(isLive ? C.signalDim : C.hairBold, lineWidth: 1)
        )
    }

    // A1: pill переиспользует state.*-ключи, срезая терминальную точку /
    // многоточие (у pill короткий UPPERCASE-бейдж без пунктуации).
    private var pillLabel: String {
        MenuBarPopover.stateWord(for: stateMgr.statusFrame.state)
    }

    /// Локализованное слово состояния без терминальной пунктуации.
    /// Используется и pill'ом (UPPERCASE), и hero-строкой (.lowercased()).
    static func stateWord(for state: ConnState) -> String {
        let key: String
        switch state {
        case .disconnected:  key = "state.standby"
        case .connecting:    key = "state.tuning"
        case .reconnecting:  key = "state.regrouping"
        case .connected:     key = "state.transmitting"
        case .error:         key = "state.lost_signal"
        }
        return L(key)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
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
                .padding(.bottom, reconnectProgressText == nil ? 18 : 6)

            // A5: под таймером показываем «попытка N · повтор через Ns»
            // когда рантайм отдал оба поля reconnect-прогресса.
            if let progress = reconnectProgressText {
                Text(progress)
                    .font(.custom("DepartureMono-Regular", size: 10.5))
                    .tracking(0.06 * 10.5)
                    .foregroundStyle(C.warn)
                    .padding(.bottom, 14)
            }

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
        // A1: lowercase-вариант тех же state.*-ключей (serif-italic hero).
        let verb = MenuBarPopover.stateWord(for: stateMgr.statusFrame.state).lowercased()
        let accent: Color
        switch stateMgr.statusFrame.state {
        case .disconnected:               accent = C.textDim
        case .connecting, .reconnecting:  accent = C.warn
        case .connected:                  accent = C.signal
        case .error:                      accent = C.danger
        }
        return (verb, accent)
    }

    /// A5: строка reconnect-прогресса. nil, если не .reconnecting или
    /// рантайм ещё не отдал attempt/delay.
    private var reconnectProgressText: String? {
        guard stateMgr.statusFrame.state == .reconnecting,
              let attempt = stateMgr.statusFrame.reconnectAttempt,
              let delay = stateMgr.statusFrame.reconnectNextDelaySecs
        else { return nil }
        return String(format: L("state.reconnect_progress"),
                      Int64(attempt), Int64(delay))
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
        // UI-R2-N20: during busy (`connecting`/`reconnecting`) the FAB
        // now shows CANCEL — a `tunnel.stop()` call — instead of a
        // disabled "TUNING…" pill. The Round 1 race on parallel
        // `installAndStart` is still prevented because `toggleConnect`
        // routes any non-disconnected state through `stop()`.
        //
        // MIG-R4-N01: when the v0.23→v0.24 migration's phase B is still
        // running we render a faint "IMPORTING…" label and the tap is
        // rejected inside `toggleConnect()` — Keychain cert/key items
        // aren't re-imported yet, so a CONNECT here would fail mTLS
        // handshake silently.
        //
        // UI-R4-R07: the CANCEL pill renders a `ProgressView` alongside
        // the label via the new `busy` parameter so users get visual
        // confirmation a teardown is in flight — TSPU servers can sit
        // on TLS for up to 75s and a static "CANCEL" gave no feedback.
        let state = stateMgr.statusFrame.state
        let live = state == .connected
        let busy = state == .connecting || state == .reconnecting
        let migrating = LegacyMigration.state.isMigrating
        let label: String = busy
            ? L("fab.cancel")
            : (live ? L("fab.disconnect")
            : (migrating ? L("fab.importing") : L("fab.connect")))
        let tint: Color = busy ? C.warn
            : (live ? C.danger
            : (migrating ? C.textFaint : C.signal))
        VStack(alignment: .leading, spacing: 8) {
            GhostFab(
                text: label,
                outline: !live,
                tint: tint,
                busy: busy
            ) {
                popoverLog.info("GhostFab tapped — live=\(live, privacy: .public) busy=\(busy, privacy: .public) migrating=\(migrating, privacy: .public)")
                Task { await toggleConnect() }
            }
            .disabled(migrating && !live && !busy)
            .help(migrating
                ? "Importing keychain items from previous version — please wait."
                : "")
            if let err = inlineConnectError {
                Text(err)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .foregroundStyle(C.danger)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Surface connect failures and prerequisite feedback inline. The wizard
    /// still opens for setup, but the tap should never look like a no-op.
    private var inlineConnectError: String? {
        if let msg = tunnel.lastError, !msg.isEmpty { return msg }
        // Фатальная причина от ядра (отзыв, сертификат, часы).
        if stateMgr.statusFrame.state == .error,
           let msg = stateMgr.statusFrame.lastError, !msg.isEmpty { return msg }
        return nil
    }

    @ViewBuilder
    private var profileBlock: some View {
        VStack(spacing: 0) {
            HairlineDivider()
            // UI-AUDIT-07/2026: шеврон chevron.up.chevron.down обещал
            // picker, но блок был статичным — сменить профиль из
            // меню-бара было нельзя. Теперь Menu, как в сайдбарном
            // SidebarProfileBlock.
            Menu {
                if profiles.profiles.isEmpty {
                    Button("No profiles") {}
                        .disabled(true)
                } else {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            profiles.setActive(id: profile.id)
                        } label: {
                            HStack {
                                Text(profile.name)
                                if profiles.activeId == profile.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                // ВАЖНО: .menuStyle(.borderlessButton) на macOS схлопывает
                // кастомный лейбл до огрызка «PROF ⌄» (даже с фоном) —
                // игнорирует предложенную ширину, Spacer уводит контент в 0.
                // Используем автоматический стиль + .buttonStyle(.plain) +
                // .menuIndicator(.hidden) (свой шеврон рисуем сами) — так
                // лейбл рендерится целиком.
                HStack(spacing: 10) {
                    Text("PROF")
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .tracking(0.18 * 9.5)
                        .foregroundStyle(C.textFaint)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profiles.activeProfile?.name ?? "—")
                                .font(.custom("SpaceGrotesk-Bold", size: 13))
                                .tracking(-0.01 * 13)
                                .foregroundStyle(C.bone)
                            if profiles.activeProfile?.relayActive == true {
                                Text("RELAY")
                                    .font(.custom("DepartureMono-Regular", size: 9))
                                    .tracking(0.12 * 9)
                                    .foregroundStyle(C.warn)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: GsRadius.chip, style: .continuous).stroke(C.warn.opacity(0.35), lineWidth: 1))
                            }
                        }
                        if let endpoint = profileEndpoint {
                            Text(endpoint)
                                .font(.custom("JetBrainsMono-Regular", size: 10.5))
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
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev2))
                .overlay(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).stroke(C.hairBold, lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Choose active profile")
            HairlineDivider()
        }
        .padding(.bottom, 14)
    }

    private var profileEndpoint: String? {
        // Фактическая точка входа: с relay это relay-адрес.
        guard let host = profiles.activeProfile?.effectiveServerAddr, !host.isEmpty else { return nil }
        return host
    }

    private var rttLabel: String {
        if let rtt = stateMgr.statusFrame.rttMs { return "\(rtt)ms" }
        return "— ms"
    }

    // MARK: - Mini scope (transmitting only)

    @ViewBuilder
    private var miniScope: some View {
        let series = traffic.series(capacity: ScopeWindow.m1.rawValue)
        let isLive = stateMgr.statusFrame.state == .connected
        let rxSamples = isLive ? series.rxSamples : []
        let txSamples = isLive ? series.txSamples : []

        ZStack(alignment: .topLeading) {
            ScopeChart(
                rxSamples: rxSamples,
                txSamples: txSamples,
                height: 64,
                sampleCapacity: series.sampleCapacity
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
                    Text(formatRate(displayRxRateBps))
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .foregroundStyle(C.bone)
                    Text(formatRate(displayTxRateBps))
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .foregroundStyle(C.textDim)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev2))
        .overlay(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).stroke(C.hair, lineWidth: 1))
        .gsClip(GsRadius.card)
    }

    @ViewBuilder
    private var muxRow: some View {
        // Per ADR 0007 the runtime is the only source of truth for
        // `nStreams`. UI follows the runtime, clamped to [1, 16].
        let bars = TelemetryDisplayHelpers.barCountFromStreams(stateMgr.statusFrame.nStreams)
        HStack(spacing: 14) {
            Text("MUX · \(stateMgr.statusFrame.streamsUp)↑\(stateMgr.statusFrame.nStreams)")
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.18 * 9.5)
                .foregroundStyle(C.textFaint)
            MuxBars(
                active: stateMgr.statusFrame.state == .connected,
                barCount: bars,
                activityLevels: stateMgr.statusFrame.streamActivity,
                reduceMotion: reduceMotion,
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
            // A4: строка появляется НАД «Открыть консоль» только когда в
            // буфере лежит ghs:// — импортирует профиль и делает активным.
            if clipboardConfig != nil {
                footerRow(
                    systemImage: "doc.on.clipboard",
                    title: L("popover.paste_config"),
                    kbd: "",
                    color: C.signal
                ) {
                    importClipboardConfig()
                }
            }
            if let status = pasteStatus {
                Text(status)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .foregroundStyle(C.danger)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            footerRow(
                systemImage: "rectangle.on.rectangle",
                title: L("menu.open_console"),
                kbd: "⌘0",
                color: C.bone
            ) {
                openForegroundWindow("console")
            }
            footerRow(
                systemImage: "command",
                title: L("menu.command_palette"),
                kbd: "⌘⇧C",
                color: C.bone
            ) {
                openForegroundWindow("console")
                router.commandPaletteOpen = true
            }
            // UI-C5: Quit is now *always* the last footer row,
            // regardless of connection state. Previously the row
            // toggled between "Logs" (connected) and "Quit"
            // (disconnected), which left users in accessory mode
            // — `showInDock=false` — with no visible way to quit
            // while the tunnel was live.
            //
            // UI-H2: "Logs" is read from the catalog instead of the
            // hardcoded "Логи" so EN locale renders correctly.
            // UI-AUDIT-07/2026: строка «Логи» видна всегда — окно логов
            // работает и в STANDBY (история прошлой сессии, ошибки
            // коннекта), прятать аффорданс по состоянию незачем; сам
            // шорткат ⌘⇧L из меню и так жил в любом состоянии.
            footerRow(
                systemImage: "clock",
                title: L("menu.logs"),
                kbd: "⌘⇧L",
                color: C.bone
            ) {
                openForegroundWindow("logs")
            }
            footerRow(
                systemImage: "power",
                title: L("menu.quit"),
                kbd: "⌘Q",
                color: C.danger
            ) {
                NSApplication.shared.terminate(nil)
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
                // Пустой kbd (напр. у paste-config строки) не должен
                // рисовать пустой хинт-бокс.
                if !kbd.isEmpty {
                    KeyboardShortcutHint(kbd)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - A4: clipboard ghs:// import

    private func refreshClipboardConfig() {
        if let str = NSPasteboard.general.string(forType: .string),
           str.hasPrefix("ghs://") {
            clipboardConfig = str
        } else {
            clipboardConfig = nil
        }
    }

    private func importClipboardConfig() {
        guard let str = clipboardConfig else { return }
        do {
            let profile = try profiles.importFromConnString(str)
            profiles.setActive(id: profile.id)
            // Успех: строка исчезает, активный профиль в PROF меняется —
            // отдельного баннера в попапе не городим (см. задачу A4).
            clipboardConfig = nil
            setPasteStatus(nil)
        } catch {
            // Ошибку НЕ пишем в tunnel.lastError (это канал коннекта) —
            // локальный danger-текст под футером с 5с TTL.
            setPasteStatus(L("popover.paste_failed"))
        }
    }

    private func setPasteStatus(_ text: String?) {
        pasteStatusTask?.cancel()
        pasteStatus = text
        guard text != nil else { return }
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            pasteStatus = nil
        }
        pasteStatusTask = task
    }

    // MARK: - Actions

    private func toggleConnect() async {
        let state = stateMgr.statusFrame.state
        // UI-R2-N20: connected → DISCONNECT, busy → CANCEL. Both route
        // to `tunnel.stop()` to let the user abort a stuck handshake
        // (TSPU servers can sit on TLS for up to 75s).
        if state == .connected || state == .connecting || state == .reconnecting {
            popoverLog.info("toggleConnect → stop (state=\(String(describing: state), privacy: .public))")
            tunnel.stop()
            return
        }

        // MIG-R4-N01: refuse CONNECT while the v0.23→v0.24 migration's
        // phase B is still running — see DashboardView.toggle() for
        // the full rationale (cert/key items not yet re-imported,
        // mTLS would fail).
        if LegacyMigration.state.isMigrating {
            popoverLog.info("toggleConnect → migration phase B still in flight, refusing CONNECT")
            tunnel.lastError = "Importing keychain items from previous version — please wait a moment and try again."
            return
        }

        if let preflightError = connectPreflightError() {
            popoverLog.info("toggleConnect → prerequisites missing, opening Welcome wizard")
            tunnel.lastError = preflightError
            openForegroundWindow("welcome")
            return
        }

        guard let profile = profiles.activeProfile else { return }
        popoverLog.info("toggleConnect → installAndStart profile=\(profile.id, privacy: .public)")
        do {
            try await tunnel.installAndStart(profile: profile, preferences: PreferencesStore.shared)
            tunnel.lastError = nil
        } catch {
            popoverLog.error("installAndStart failed: \(error.localizedDescription, privacy: .public)")
            tunnel.lastError = ConnectErrorHumanizer.humanize(error.localizedDescription)
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

    private func formatRate(_ bps: Double) -> String {
        let kb = bps / 1024.0
        if kb < 1024 {
            return String(format: "%.2f KB/S", kb)
        }
        return String(format: "%.2f MB/S", kb / 1024.0)
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
