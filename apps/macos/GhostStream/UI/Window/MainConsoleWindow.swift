//
//  MainConsoleWindow.swift
//  GhostStream (macOS)
//
//  Нативный каркас окна (ADR 0022, mockup.html): системный сайдбар с чипом
//  профиля внизу, тулбар с чипом и главной кнопкой, баннер обновления над
//  экраном. Command Palette — overlay.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct MainConsoleWindow: View {

    @Environment(\.gsColors) private var C
    @Environment(AppRouter.self) private var router
    @Environment(ProfilesStore.self) private var profiles
    @Environment(UpdateChecker.self) private var updates

    public init() {}

    /// Админка видна только админской идентичности (кэш `/api/me`).
    private var adminUnlocked: Bool {
        profiles.activeProfile?.cachedIsAdmin == true
    }

    public var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 240, ideal: 252, max: 300)
            } detail: {
                detail
                    .navigationTitle(L(router.selectedChannel.localizedKey))
                    .toolbar { toolbar }
            }
            // UI-R2-R02: пока открыта палитра, шорткаты и клики под ней
            // не должны срабатывать.
            .disabled(router.commandPaletteOpen)

            if router.commandPaletteOpen {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        // Старые экраны рассчитаны на ~820 pt детали + сайдбар.
        .frame(minWidth: 1040, minHeight: 680)
        // Админский профиль сменился на обычный — не оставляем пользователя
        // на пропавшем пункте.
        .onChange(of: adminUnlocked) { _, unlocked in
            if !unlocked && router.selectedChannel == .admin {
                router.select(.stream)
            }
        }
    }

    /// Системный список; выделение рисуем сами, как в макете (lime 15 %,
    /// иконка lime): системное — синий accent с белым текстом, а lime-accent
    /// с белым текстом не читается. Поэтому selection всегда отдаёт nil —
    /// клик доходит до роутера, системная подсветка не рисуется.
    private var sidebar: some View {
        List(SidebarChannel.visible(adminUnlocked: adminUnlocked), selection: Binding<SidebarChannel?>(
            get: { nil },
            set: { if let channel = $0 { router.select(channel) } }
        )) { channel in
            let selected = router.selectedChannel == channel
            Label {
                Text(L(channel.localizedKey))
            } icon: {
                Image(systemName: channel.sfSymbol)
                    .foregroundStyle(selected ? C.signal : C.textDim)
            }
            .tag(channel)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? C.signal.opacity(0.15) : .clear)
                    .padding(.horizontal, 10)
            )
        }
        .safeAreaInset(edge: .bottom) {
            ProfileChip(showsAccess: true)
                .padding(10)
        }
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let release = updates.available, !updates.bannerDismissed {
                UpdateBanner(release: release) { updates.bannerDismissed = true }
                    .padding(.horizontal, GsSpace.xxl)
                    .padding(.top, GsSpace.s)
            }
            detailPane
        }
        .background(C.bg)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if !profiles.profiles.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                ProfileChip()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            ConnectButton()
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch router.selectedChannel {
        case .stream:  DashboardView()
        case .tail:    TailView()
        case .setup:   SettingsView()
        case .roster:  ServerRosterView()
        case .admin:   AdminConsoleView()
        }
    }
}
