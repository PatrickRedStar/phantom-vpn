//
//  MenuBarPopover.swift
//  GhostStream (macOS)
//
//  Попап строки меню (mockup.html, `.pop`): строка обновления, состояние
//  с временем сессии, скорость, предупреждение, главная кнопка, выбор
//  профиля, «Открыть GhostStream» / «Настройки…» / «Выйти». Высота — по
//  содержимому.
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct MenuBarPopover: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TrafficSeriesStore.self) private var traffic
    @Environment(ProfilesStore.self) private var profiles
    @Environment(AppRouter.self) private var router
    @Environment(DockPolicyController.self) private var dock
    @Environment(UpdateChecker.self) private var updates
    @EnvironmentObject private var tunnel: VpnTunnelController

    @State private var pasteError: String?
    @State private var size: CGSize = .zero

    public init() {}

    private var frame: StatusFrame { stateMgr.statusFrame }
    private var state: ConnState { frame.state }
    private var noProfiles: Bool { profiles.profiles.isEmpty }
    private var issue: DashIssue? {
        DashIssue.current(frame: frame, tunnelError: tunnel.lastError,
                          profileName: profiles.activeProfile?.name ?? "")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let release = updates.available {
                updateRow(release)
                    .padding(.bottom, 10)
            }
            header
            Text(noProfiles ? L("popover.no_profiles") : (profiles.activeProfile?.name ?? L("profile.none")))
                .gsType(.caption)
                .foregroundStyle(C.textDim)
                .lineLimit(1)
                .padding(.leading, 23)
                .padding(.trailing, 6)
                .padding(.top, 2)
                .padding(.bottom, GsSpace.m)
            if state == .connected && !noProfiles {
                rates
                    .padding(.bottom, GsSpace.m)
            }
            if let note = noteContent {
                noteView(note)
                    .padding(.bottom, GsSpace.m)
            }
            mainButton
            if !noProfiles {
                separator
                Text(L("popover.profile"))
                    .gsType(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(C.textDim)
                    .padding(.horizontal, GsSpace.s)
                    .padding(.top, 2)
                    .padding(.bottom, GsSpace.xs)
                // Много профилей — прокрутка, попап не выше ~8 строк.
                if profiles.profiles.count > Self.maxProfileRows {
                    ScrollView {
                        VStack(spacing: 0) { profileRows }
                    }
                    .frame(height: CGFloat(Self.maxProfileRows) * MenuRow.height)
                } else {
                    profileRows
                }
            }
            separator
            MenuRow(title: L("popover.open"), trailing: "⌘0") { openForeground("console") }
            MenuRow(title: L("menu.settings"), trailing: "⌘,") {
                router.select(.setup)
                openForeground("console")
            }
            MenuRow(title: L("menu.quit"), trailing: "⌘Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(GsSpace.m)
        .frame(width: 306)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .background(FitWindowToContent(size: size))
        .background(C.bg.opacity(0.85))
        .task { traffic.start(stateManager: stateMgr) }
        // Тот же флаг удачной сессии, что и на «Главной».
        .onChange(of: state) { _, newState in
            tunnel.observeStateForSuccessTracking(newState)
        }
    }

    private static let maxProfileRows = 8

    private var profileRows: some View {
        ForEach(profiles.profiles) { profile in
            let active = profile.id == profiles.activeId
            MenuRow(title: profile.name, checked: active,
                    trailing: active && state == .connected ? frame.rttMs.map { String(format: L("unit.ms"), Int64($0)) } : nil) {
                profiles.setActive(id: profile.id)
            }
        }
    }

    // MARK: - Header

    /// Плохая связь при поднятом туннеле — тоном предупреждения, а не lime.
    private var tone: Color {
        if noProfiles { return C.textFaint }
        if state == .connected, issue != nil { return C.warn }
        return state.tone(C)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(tone)
                .frame(width: 8, height: 8)
            Text(noProfiles ? L("profile.none") : state.title)
                .gsType(.headline)
                .fontWeight(.bold)
                .foregroundStyle(noProfiles || state == .disconnected ? C.bone : tone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: GsSpace.s)
            if !noProfiles && (state == .connected || state == .reconnecting) {
                Text(DashFormat.duration(frame.sessionSecs))
                    .gsType(.metricSmall)
                    .foregroundStyle(C.bone)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, GsSpace.xs)
    }

    private func updateRow(_ release: UpdateChecker.Release) -> some View {
        HStack(spacing: GsSpace.s) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15))
                .foregroundStyle(C.signal)
            Text(String(format: L("update.available"), release.version))
                .gsType(.caption)
                .foregroundStyle(C.bone)
            Spacer(minLength: GsSpace.s)
            Button(L("update.download")) { NSWorkspace.shared.open(release.url) }
                .buttonStyle(.plain)
                .gsType(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(C.signal)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, GsSpace.s)
        .background(C.signal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 2)
    }

    // MARK: - Speed

    private var rates: some View {
        HStack(spacing: 18) {
            rate(rx: true)
            rate(rx: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GsSpace.m)
        .padding(.vertical, 10)
        .background(C.bone.opacity(0.05), in: RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous))
        .padding(.horizontal, 2)
    }

    private func rate(rx: Bool) -> some View {
        let sampled = rx ? traffic.currentRxRateBps : traffic.currentTxRateBps
        let bytes = sampled > 0 ? sampled
            : TelemetryDisplayHelpers.bytesPerSecondFromBitsPerSecond(rx ? frame.rateRxBps : frame.rateTxBps)
        let (value, unit) = DashFormat.rate(bytes)
        return HStack(spacing: 5) {
            Image(systemName: rx ? "arrow.down" : "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(rx ? C.signal : C.warn)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .gsType(.metricSmall)
                    .foregroundStyle(C.bone)
                Text(unit)
                    .font(.system(size: 11.5))
                    .foregroundStyle(C.textDim)
            }
        }
    }

    // MARK: - Note

    private struct Note {
        let tone: Color
        let title: String
        let text: String
    }

    private var noteContent: Note? {
        if let pasteError { return Note(tone: C.danger, title: L("dash.paste_link"), text: pasteError) }
        if noProfiles { return Note(tone: C.bone, title: L("dash.empty.title"), text: L("popover.empty.text")) }
        guard let issue else { return nil }
        return Note(tone: issue.danger ? C.danger : C.warn, title: issue.title, text: issue.text)
    }

    private func noteView(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title)
                .gsType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(note.tone)
            if !note.text.isEmpty {
                Text(note.text)
                    .gsType(.caption)
                    .foregroundStyle(C.bone)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, GsSpace.m)
        .padding(.vertical, 10)
        .background(note.tone.opacity(0.13), in: RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous))
        .padding(.horizontal, 2)
    }

    // MARK: - Main button

    @ViewBuilder
    private var mainButton: some View {
        // Без профиля и при отозванном доступе главное действие — новая ссылка.
        let paste = noProfiles || (state == .error && issue?.canPaste == true)
        let (title, prominent) = paste ? (L("dash.paste_link"), true) : ConnectButton.label(for: state)
        let button = Button {
            if paste {
                pasteError = DashPaste.importFromClipboard(profiles)
            } else {
                Task { await ConnectAction.toggle { openForeground("welcome") } }
            }
        } label: {
            Label(title, systemImage: paste ? "link" : "power")
                .labelStyle(.titleAndIcon)
                .gsType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(prominent ? C.bg : C.bone)
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!paste && (profiles.activeProfile == nil
                             || (state == .disconnected && LegacyMigration.state.isMigrating)))

        if prominent {
            button.gsProminentButton(tint: C.signal)
        } else {
            button.gsGlassButton()
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(C.bone.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
    }

    private func openForeground(_ id: String) {
        openWindow(id: id)
        dock.activateForegroundWindow()
    }
}

/// Пункт меню попапа (`.mi`): галочка, название, подсказка справа;
/// под курсором — lime-подсветка, как у системного меню.
private struct MenuRow: View {
    let title: String
    var checked = false
    var trailing: String?
    let action: () -> Void

    static let height: CGFloat = 28

    @Environment(\.gsColors) private var C
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: GsSpace.s) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 13)
                    .opacity(checked ? 1 : 0)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: GsSpace.s)
                if let trailing {
                    Text(trailing)
                        .gsType(.caption)
                        .foregroundStyle(hover ? C.bg.opacity(0.8) : C.textDim)
                }
            }
            .gsType(.body)
            .foregroundStyle(hover ? C.bg : C.bone)
            .padding(.horizontal, GsSpace.s)
            .frame(height: Self.height)
            .background(hover ? C.signal : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// MenuBarExtra(.window) не всегда подгоняет окно под новый размер
/// содержимого (UI-POPOVER-CLIP: попап, впервые открытый коротким,
/// обрезал длинное состояние). Подгоняем окно сами, верхний край на месте.
private struct FitWindowToContent: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let size = size
        DispatchQueue.main.async {
            guard let window = view.window, size.width > 0, size.height > 0 else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            guard abs(content.width - size.width) > 0.5 || abs(content.height - size.height) > 0.5 else { return }
            let target = NSRect(x: content.minX, y: content.maxY - size.height,
                                width: size.width, height: size.height)
            window.setFrame(window.frameRect(forContentRect: target), display: true)
        }
    }
}

// MARK: - Brand glyph (About, Welcome)

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
