//
//  DashboardView.swift
//  GhostStream (macOS)
//
//  «Главная» (mockup.html, `data-pane="home"`): состояние словами, время
//  сессии, проблема с причиной, скорость с графиком, срок доступа и
//  карточка подключения; без профилей — «Добавьте профиль».
//  Заголовок экрана, баннер обновления и кнопку «Подключить/Отключить»
//  рисует каркас (MainConsoleWindow).
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct DashboardView: View {

    @Environment(\.gsColors) private var C
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TrafficSeriesStore.self) private var traffic
    @Environment(ProfilesStore.self) private var profiles
    @Environment(AppRouter.self) private var router
    @EnvironmentObject private var tunnel: VpnTunnelController

    /// Окно графика, секунд.
    @State private var window = 60
    @State private var pasteError: String?

    public init() {}

    public var body: some View {
        ScrollView {
            Group {
                if profiles.profiles.isEmpty { emptyState } else { content }
            }
            .padding(.horizontal, GsSpace.xxl)
            .padding(.top, GsSpace.l)
            .padding(.bottom, GsSpace.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(C.bg)
        .task { traffic.start(stateManager: stateMgr) }
        // Ошибка коннекта гасится только после удачной сессии — флаг общий
        // с попапом (VpnTunnelController.hadSuccessfulConnect).
        .onChange(of: stateMgr.statusFrame.state) { _, newState in
            tunnel.observeStateForSuccessTracking(newState)
        }
    }

    private var frame: StatusFrame { stateMgr.statusFrame }
    private var state: ConnState { frame.state }
    private var profile: VpnProfile? { profiles.activeProfile }
    private var name: String { profile?.name ?? L("profile.none") }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let issue = DashIssue.current(frame: frame, tunnelError: tunnel.lastError, profileName: name)
        VStack(alignment: .leading, spacing: GsSpace.l) {
            hero
                .padding(.bottom, 6)
            if let issue { banner(issue) }
            if state == .connected || state == .reconnecting {
                HStack(alignment: .top, spacing: GsSpace.l) {
                    speedCard
                    VStack(spacing: GsSpace.l) {
                        accessCard
                        connectionCard
                    }
                    .frame(width: 300)
                }
                // Правая колонка тянется до высоты карточки скорости.
                .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: GsSpace.l) {
                    if state != .error { accessCard.fixedSize() }
                    connectionCard
                }
            }
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: GsSpace.xl) {
            StatusHeadline(state: state, subtitle: subtitle)
            Spacer(minLength: 0)
            if state == .connected || state == .reconnecting {
                VStack(alignment: .trailing, spacing: 7) {
                    Text(DashFormat.duration(frame.sessionSecs))
                        .gsType(.metric)
                        .foregroundStyle(C.bone)
                    Text(L(state == .reconnecting ? "dash.session_continues" : "dash.session_time"))
                        .gsType(.caption)
                        .foregroundStyle(C.textDim)
                }
            }
        }
    }

    private var subtitle: String {
        switch state {
        case .connecting:   return String(format: L("dash.sub.connecting"), name)
        case .disconnected: return String(format: L("dash.sub.disconnected"), name)
        default:            return name
        }
    }

    // MARK: - Banner (переподключение, ошибка, плохая связь)

    private func banner(_ issue: DashIssue) -> some View {
        let tone = issue.danger ? C.danger : C.warn
        let shape = RoundedRectangle(cornerRadius: GsRadius.panel, style: .continuous)
        // В баннере переподключения — ещё и обещание, что сессия переживёт.
        let text = state == .reconnecting
            ? [issue.text, L("dash.reconnect.keep")].filter { !$0.isEmpty }.joined(separator: ". ")
            : issue.text
        return HStack(alignment: issue.danger ? .top : .center, spacing: 14) {
            Image(systemName: issue.icon)
                .font(.system(size: 22))
                .foregroundStyle(tone)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .gsType(.headline)
                    .foregroundStyle(C.bone)
                Text(text)
                    .gsType(.body)
                    .foregroundStyle(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                if issue.danger {
                    HStack(spacing: GsSpace.s) {
                        if issue.canPaste { pasteButton(large: false) }
                        Button(L("dash.open_logs")) { router.select(.tail) }
                            .gsType(.body)
                            .foregroundStyle(C.bone)
                            .gsGlassButton()
                    }
                    .padding(.top, 9)
                    if let pasteError {
                        Text(pasteError)
                            .gsType(.caption)
                            .foregroundStyle(C.danger)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, GsSpace.l)
        .padding(.horizontal, 18)
        .background(shape.fill(C.bg).overlay(shape.fill(tone.opacity(0.10))))
        .overlay(shape.stroke(tone.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Speed

    private var speedCard: some View {
        let live = state == .connected
        let series = traffic.series(capacity: window)
        // При переподключении график остаётся, но замирает (см. ниже).
        let rx = series.rxSamples
        let tx = series.txSamples
        // Тот же пик, к которому ScopeChart нормирует обе линии.
        let peak = max(rx.max() ?? 0, tx.max() ?? 0)
        return GsCard {
            HStack {
                Text(L("dash.speed"))
                    .gsType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(C.textDim)
                Spacer()
                Picker("", selection: $window) {
                    Text(L("dash.window.1m")).tag(60)
                    Text(L("dash.window.5m")).tag(300)
                    Text(L("dash.window.15m")).tag(900)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .tint(C.signal)
            }
            Group {
                HStack(spacing: 40) {
                    rate(displayRate(rx: true), up: false, live: live)
                    rate(displayRate(rx: false), up: true, live: live)
                }
                .padding(.top, 2)
                .padding(.bottom, 2)
                ScopeChart(rxSamples: rx, txSamples: tx, height: 168, sampleCapacity: series.sampleCapacity)
                    .overlay(alignment: .topTrailing) {
                        if peak > 0 { axisLabel(peak).offset(y: -7) }
                    }
                    .overlay(alignment: .trailing) {
                        if peak > 0 { axisLabel(peak / 2) }
                    }
            }
            // Переподключение: цифры и график замирают.
            .opacity(live ? 1 : 0.35)
            .grayscale(live ? 0 : 1)
            VStack(spacing: GsSpace.m) {
                Rectangle().fill(C.hair).frame(height: 1)
                HStack(spacing: 10) {
                    streamBars(live: live)
                    Text(String(format: L("dash.streams"),
                                Int64(live ? frame.streamsUp : 0), Int64(frame.nStreams)))
                    Spacer(minLength: GsSpace.s)
                    Text(String(format: L("dash.totals"),
                                DashFormat.bytes(frame.bytesRx), DashFormat.bytes(frame.bytesTx)))
                        .lineLimit(1)
                }
                .gsType(.caption)
                .foregroundStyle(C.textDim)
            }
        }
    }

    private func rate(_ bytesPerSec: Double, up: Bool, live: Bool) -> some View {
        let tone = up ? C.warn : C.signal
        let (value, unit) = live ? DashFormat.rate(bytesPerSec) : ("—", L("unit.mbps"))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: up ? "arrow.up" : "arrow.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tone)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .gsType(.metric)
                        .foregroundStyle(C.bone)
                    Text(unit)
                        .gsType(.body)
                        .foregroundStyle(C.textDim)
                }
            }
            HStack(spacing: 6) {
                Capsule().fill(tone).frame(width: 12, height: 2)
                Text(L(up ? "dash.upload" : "dash.download"))
                    .gsType(.caption)
                    .foregroundStyle(C.textDim)
            }
            .padding(.leading, 24)
        }
    }

    private func axisLabel(_ bytesPerSec: Double) -> some View {
        Text(DashFormat.rate(bytesPerSec).value)
            .font(.system(size: 10.5))
            .foregroundStyle(C.textDim)
            .padding(.leading, 4)
            .background(C.bgElev)
    }

    /// Активность каналов (макет `.mux`): столбик на поток.
    private func streamBars(live: Bool) -> some View {
        let count = min(max(Int(frame.nStreams), 1), 16)
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                let level = live && i < frame.streamActivity.count ? CGFloat(frame.streamActivity[i]) : 0.4
                Capsule()
                    .fill(live ? C.signal : C.hairBold)
                    .frame(width: 4, height: 6 + 10 * level)
            }
        }
        .frame(height: 16, alignment: .bottom)
    }

    /// Байт/с: из выборки графика, иначе из StatusFrame (там бит/с).
    private func displayRate(rx: Bool) -> Double {
        let sampled = rx ? traffic.currentRxRateBps : traffic.currentTxRateBps
        if sampled > 0 { return sampled }
        return TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(rx ? frame.rateRxBps : frame.rateTxBps)
    }

    // MARK: - Access & connection

    @ViewBuilder
    private var accessCard: some View {
        if let expires = profile?.cachedExpiresAt {
            let date = Date(timeIntervalSince1970: TimeInterval(expires))
            let day = date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))
            let days = Int((date.timeIntervalSinceNow / 86_400).rounded(.up))
            let tone = days > 0 ? C.signal : C.danger
            GsCard {
                HStack(spacing: 14) {
                    Image(systemName: "calendar")
                        .font(.system(size: 19))
                        .foregroundStyle(tone)
                        .frame(width: 42, height: 42)
                        .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(days > 0 ? String(format: L("dash.access_until"), day)
                                      : String(format: L("profile.access_expired"), day))
                            .gsType(.headline)
                            .foregroundStyle(C.bone)
                        Text(days > 0 ? String(format: L("dash.days_left"), Int64(days)) : L("dash.access_extend"))
                            .gsType(.body)
                            .foregroundStyle(C.textDim)
                    }
                }
            }
        }
    }

    private var connectionCard: some View {
        GsCard(L("dash.connection")) {
            VStack(spacing: 0) {
                kv(L("dash.server"), first: true) { Text(name) }
                kv(L("dash.route")) {
                    Text(L(profile?.relayActive == true ? "dash.route.relay" : "dash.route.direct"))
                }
                if let address = vpnAddress {
                    kv(L("dash.vpn_address")) { Text(address).gsType(.mono) }
                }
                if let dns = DashFormat.dns(frame.dnsObserved) {
                    kv(L("dash.dns")) {
                        HStack(spacing: 0) {
                            Text(dns.host).gsType(.mono)
                            if dns.encrypted { Text(" · " + L("dash.dns.encrypted")) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func kv<V: View>(_ label: String, first: Bool = false, @ViewBuilder value: () -> V) -> some View {
        HStack(spacing: GsSpace.m) {
            Text(label).foregroundStyle(C.textDim)
            Spacer(minLength: GsSpace.m)
            value()
                .foregroundStyle(C.bone)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .gsType(.body)
        .padding(.top, first ? 0 : 9)
        .padding(.bottom, 9)
        .overlay(alignment: .top) {
            if !first { Rectangle().fill(C.hair).frame(height: 1) }
        }
    }

    /// «10.7.0.12» — адрес клиента внутри VPN, без маски.
    private var vpnAddress: String? {
        let raw = frame.tunAddr ?? profile?.tunAddr ?? ""
        let ip = raw.split(separator: "/").first.map(String.init) ?? ""
        return ip.isEmpty ? nil : ip
    }

    // MARK: - Empty

    private var emptyState: some View {
        let parts = L("dash.empty.text").components(separatedBy: "%@")
        return VStack(spacing: GsSpace.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 116, height: 116)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 10)
                .padding(.bottom, 6)
            Text(L("dash.empty.title"))
                .gsType(.title)
                .foregroundStyle(C.bone)
            Text("\(parts.first ?? "")\(Text("ghs://…").font(GsType.mono.font).foregroundStyle(C.bone))\(parts.dropFirst().joined())")
                .gsType(.body)
                .foregroundStyle(C.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            pasteButton(large: true)
                .padding(.top, 10)
            Text(pasteError ?? L("dash.empty.hint"))
                .gsType(.caption)
                .foregroundStyle(pasteError == nil ? C.textDim : C.danger)
        }
        .frame(maxWidth: .infinity, minHeight: 560)
    }

    /// «Вставить ссылку»; ⌘V в окне делает то же самое.
    private func pasteButton(large: Bool) -> some View {
        Button {
            pasteError = DashPaste.importFromClipboard(profiles)
        } label: {
            Label(L("dash.paste_link"), systemImage: "link")
                .gsType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(C.bg)
                .padding(.horizontal, large ? GsSpace.xs : 0)
        }
        .controlSize(large ? .large : .regular)
        .gsProminentButton(tint: C.signal)
        .keyboardShortcut("v", modifiers: .command)
    }
}

// MARK: - Shared with the menu-bar popover

/// Что не так прямо сейчас — человеческими словами: переподключение с
/// причиной и отсчётом, фатальная остановка, неудачный коннект, плохая связь.
struct DashIssue {
    var danger: Bool
    var icon: String
    var title: String
    var text: String
    /// Лечится новой ссылкой (доступ отозван / истёк / сертификат профиля).
    var canPaste = false

    @MainActor
    static func current(frame: StatusFrame, tunnelError: String?, profileName: String) -> DashIssue? {
        let english = (LocalizationManager.shared.language ?? Bundle.main.preferredLocalizations.first) == "en"
        switch frame.state {
        case .reconnecting:
            let reason = nonEmpty(frame.lastError).map {
                firstSentence(ConnectErrorHumanizer.humanize($0, english: english))
            }
            var progress = ""
            if let attempt = frame.reconnectAttempt, let delay = frame.reconnectNextDelaySecs {
                progress = String(format: L("dash.reconnect.progress"), Int64(attempt), Int64(delay))
            }
            return DashIssue(danger: false, icon: "wifi.slash",
                             title: reason ?? L("dash.reconnect.lost"), text: progress)

        case .error:
            let raw = nonEmpty(frame.lastError) ?? nonEmpty(tunnelError) ?? ""
            let fatal = ConnectErrorHumanizer.fatalStop(raw, profileName: profileName, english: english)
            // «VPN остановлен: доступ отозван» → «Доступ отозван»; без
            // известной причины — «Не удалось подключиться».
            let generic = fatal.body == ConnectErrorHumanizer.humanize(raw, english: english)
            let cause = fatal.title.components(separatedBy: ": ").last ?? fatal.title
            let lower = raw.lowercased()
            return DashIssue(danger: true, icon: "xmark.shield",
                             title: generic ? L("dash.connect_failed") : cause.prefix(1).uppercased() + cause.dropFirst(),
                             text: fatal.body,
                             canPaste: ["доступ", "revoked", "access", "ghs://"].contains { lower.contains($0) })

        case .disconnected:
            guard let error = nonEmpty(tunnelError) else { return nil }
            return DashIssue(danger: true, icon: "exclamationmark.triangle",
                             title: L("dash.connect_failed"), text: error,
                             canPaste: error.contains("ghs://"))

        case .connected:
            switch frame.health {
            case .dead?:
                return DashIssue(danger: false, icon: "wifi.exclamationmark",
                                 title: L("health.dead.title"), text: L("health.dead.text"))
            case .degraded? where frame.bandwidthClass == .throttled:
                return DashIssue(danger: false, icon: "tortoise",
                                 title: L("health.throttled.title"), text: L("health.throttled.text"))
            case .degraded?:
                return DashIssue(danger: false, icon: "wifi.exclamationmark",
                                 title: L("health.degraded.title"),
                                 text: String(format: L("health.degraded.text"),
                                              Int64(frame.streamsUp), Int64(frame.nStreams)))
            case .stale?:
                return DashIssue(danger: false, icon: "wifi.exclamationmark",
                                 title: L("health.stale.title"),
                                 text: String(format: L("health.stale.text"), Int64(frame.idleRxSecs ?? 0)))
            default:
                return nil
            }

        case .connecting:
            return nil
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// «Нет сети. Проверьте подключение…» → «Нет сети».
    private static func firstSentence(_ s: String) -> String {
        s.components(separatedBy: ". ").first ?? s
    }
}

enum DashFormat {
    /// Байт/с → («48,2», «Мбит/с»); до мегабита — в килобитах.
    @MainActor
    static func rate(_ bytesPerSec: Double) -> (value: String, unit: String) {
        let bits = max(bytesPerSec, 0) * 8
        if bits < 1_000_000 {
            return ((bits / 1_000).formatted(.number.precision(.fractionLength(0))), L("unit.kbps"))
        }
        let mbit = bits / 1_000_000
        return (mbit.formatted(.number.precision(.fractionLength(mbit < 100 ? 1 : 0))), L("unit.mbps"))
    }

    /// 5077 → «1:24:37».
    static func duration(_ secs: UInt64) -> String {
        String(format: "%d:%02d:%02d", Int(secs / 3600), Int(secs / 60 % 60), Int(secs % 60))
    }

    /// «1,92 ГБ».
    static func bytes(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory))
    }

    /// «1.1.1.1:853» → (1.1.1.1, зашифрован: DoT).
    static func dns(_ observed: String?) -> (host: String, encrypted: Bool)? {
        guard let observed, let colon = observed.lastIndex(of: ":") else { return nil }
        let host = observed[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return host.isEmpty ? nil : (host, observed[observed.index(after: colon)...] == "853")
    }
}

@MainActor
enum DashPaste {
    /// Импорт ghs:// из буфера тем же путём, что в «Серверах» и раньше в
    /// попапе: профиль добавляется и становится активным. nil — успех,
    /// иначе текст ошибки.
    static func importFromClipboard(_ profiles: ProfilesStore) -> String? {
        let link = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard link.hasPrefix("ghs://") else { return L("dash.paste.no_link") }
        do {
            let profile = try profiles.importFromConnString(link)
            profiles.setActive(id: profile.id)
            return nil
        } catch {
            return L("popover.paste_failed")
        }
    }
}
