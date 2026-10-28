//
//  StatusViews.swift
//  GhostStream (macOS)
//
//  Состояние туннеля человеческими словами (mockup.html): слово и тон,
//  точка, заголовок главной и чип профиля (тулбар и низ сайдбара).
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

extension ConnState {
    /// Отключено / Подключение… / Подключено / Переподключение… / Ошибка.
    @MainActor var title: String {
        switch self {
        case .disconnected: return L("status.disconnected")
        case .connecting:   return L("status.connecting")
        case .connected:    return L("status.connected")
        case .reconnecting: return L("status.reconnecting")
        case .error:        return L("status.error")
        }
    }

    /// Тон состояния: lime — работает, оранжевый — в процессе, красный — ошибка.
    func tone(_ C: GsColorSet) -> Color {
        switch self {
        case .connected:                 return C.signal
        case .connecting, .reconnecting: return C.warn
        case .error:                     return C.danger
        case .disconnected:              return C.textFaint
        }
    }
}

/// Точка состояния; в процессе подключения пульсирует.
struct StateDot: View {
    let state: ConnState
    var size: CGFloat = 8

    @Environment(\.gsColors) private var C
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let busy = (state == .connecting || state == .reconnecting) && !reduceMotion
        Circle()
            .fill(state.tone(C))
            .frame(width: size, height: size)
            .phaseAnimator(busy ? [1.0, 0.3] : [1.0]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.65) }
    }
}

/// Заголовок главной (макет `.hero .status`): точка с ореолом и слово 44 pt.
struct StatusHeadline: View {
    let state: ConnState
    var subtitle: String?

    @Environment(\.gsColors) private var C

    var body: some View {
        let tone = state.tone(C)
        VStack(alignment: .leading, spacing: GsSpace.s) {
            HStack(spacing: 14) {
                StateDot(state: state, size: 14)
                    .background(Circle().fill(tone.opacity(0.18)).padding(-5))
                    .shadow(color: state == .disconnected ? .clear : tone.opacity(0.55), radius: 9)
                Text(state.title)
                    .gsType(.display)
                    .tracking(-1.1)
                    .foregroundStyle(state == .disconnected ? C.bone : tone)
                    .lineLimit(1)
            }
            if let subtitle {
                Text(subtitle)
                    .gsType(.body)
                    .foregroundStyle(C.textDim)
                    .padding(.leading, 28)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Чип активного профиля: меню переключает профиль, правит и добавляет. В
/// тулбаре — одна строка, в сайдбаре (`showsAccess`) — плюс срок доступа и
/// стеклянная подложка. Без профилей в сайдбаре — кнопка «вставить ссылку».
struct ProfileChip: View {
    var showsAccess = false

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow
    @Environment(ProfilesStore.self) private var profiles
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(AppRouter.self) private var router
    @Environment(DockPolicyController.self) private var dock
    @EnvironmentObject private var tunnel: VpnTunnelController

    var body: some View {
        if profiles.profiles.isEmpty {
            // Ссылка в буфере — сразу профиль, иначе мастер с полем вставки.
            Button {
                if DashPaste.importFromClipboard(profiles) != nil {
                    openWindow(id: "welcome")
                    dock.activateForegroundWindow()
                }
            } label: {
                sidebarLabel
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                ForEach(profiles.profiles) { profile in
                    Toggle(profile.name, isOn: Binding(
                        get: { profiles.activeProfile?.id == profile.id },
                        set: { if $0 { profiles.setActive(id: profile.id) } }
                    ))
                }
                Divider()
                if let active = profiles.activeProfile {
                    Button(L("chip.edit")) { router.profileSheet = .edit(active.id) }
                }
                Button(L("chip.add")) { router.profileSheet = .add }
            } label: {
                if showsAccess { sidebarLabel } else { toolbarLabel }
            }
            // Свой шеврон (chevron.up.chevron.down) в обоих местах; в сайдбаре
            // plain, иначе Menu схлопывает лейбл до «иконка + текст».
            .menuIndicator(.hidden)
            .modifier(SidebarMenuStyle(enabled: showsAccess))
            .accessibilityLabel(L("profile.choose"))
        }
    }

    private var state: ConnState { stateMgr.statusFrame.state }

    private var name: String { profiles.activeProfile?.name ?? L("profile.none") }

    /// Тулбар превращает лейбл Menu в «иконка + заголовок»: точка — иконкой,
    /// шеврон — картинкой внутри заголовка.
    private var toolbarLabel: some View {
        Label {
            Text("\(name)  \(Image(systemName: "chevron.up.chevron.down"))")
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(nsImage: Self.dot(NSColor(state.tone(C))))
        }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: 200)
    }

    /// Точка 8 pt картинкой (тулбар масштабирует SF-символы до размера
    /// иконки) и 6 pt воздуха до названия.
    private static func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 8), flipped: false) { _ in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
            return true
        }
    }

    @ViewBuilder
    private var sidebarLabel: some View {
        let shape = RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous)
        HStack(spacing: 10) {
            StateDot(state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .gsType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(C.bone)
                    .lineLimit(1)
                Text(subtitle)
                    .gsType(.caption)
                    .foregroundStyle(C.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: profiles.profiles.isEmpty ? "plus" : "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(C.textDim)
        }
        .padding(.horizontal, GsSpace.m)
        .padding(.vertical, 10)
        .contentShape(shape)
        .modifier(GlassSurface(shape: shape))
    }

    /// Вторая строка сайдбарного чипа — всегда есть, чтобы высота не прыгала:
    /// проблема, если есть, иначе срок доступа.
    private var subtitle: String {
        guard let profile = profiles.activeProfile else { return L("profile.none_hint") }
        if state == .reconnecting { return state.title }
        if state == .error {
            return DashIssue.current(frame: stateMgr.statusFrame, tunnelError: tunnel.lastError,
                                     profileName: profile.name)?.title ?? state.title
        }
        guard let expires = profile.cachedExpiresAt else { return L("profile.access_unlimited") }
        let date = Date(timeIntervalSince1970: TimeInterval(expires))
        let day = date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))
        let days = Int((date.timeIntervalSinceNow / 86_400).rounded(.up))
        return days > 0
            ? String(format: L("profile.access_until"), day, days)
            : String(format: L("profile.access_expired"), day)
    }
}

private struct SidebarMenuStyle: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// Стеклянная подложка самописного контрола (не кнопки): glass на macOS 26,
/// материал раньше.
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
