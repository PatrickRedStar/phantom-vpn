//
//  MainConsoleWindow.swift
//  GhostStream (macOS)
//
//  Нативный каркас окна (ADR 0022, mockup.html): системный сайдбар с чипом
//  профиля внизу, тулбар «кнопки экрана → чип → главная кнопка», баннер
//  обновления над экраном. Command Palette — overlay.
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
                    .environment(\.gsInConsole, true)
                    // Один фон тулбара на всех вкладках: Form и инспектор
                    // иначе красят полосу по-своему и она мигает.
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            // UI-R2-R02: пока открыта палитра, шорткаты и клики под ней
            // не должны срабатывать.
            .disabled(router.commandPaletteOpen)

            if router.commandPaletteOpen {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        // Уже — тулбар «Серверов» (поиск, +, чип, кнопка) уходит в «»».
        .frame(minWidth: 960, minHeight: 640)
        .sheet(item: Bindable(router).profileSheet) { sheet in
            switch sheet {
            case .add:          ProfileEditorSheet()
            case .edit(let id): ProfileEditorSheet(editProfileId: id)
            }
        }
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
            // В «Админе» баннер лёг бы поверх колонки инспектора.
            if let release = updates.available, !updates.bannerDismissed, router.selectedChannel != .admin {
                UpdateBanner(release: release) { updates.dismissBanner() }
                    .padding(.horizontal, GsSpace.xxl)
                    .padding(.top, GsSpace.s)
            }
            detailPane
        }
        .background(C.bg)
    }

    @ViewBuilder
    private var detailPane: some View {
        // Серверы, Логи и Админ ставят ConsoleToolbarItems в конец своего
        // `.toolbar` — после своих кнопок.
        switch router.selectedChannel {
        case .stream:  DashboardView().toolbar { ConsoleToolbarItems() }
        case .tail:    TailView()
        case .setup:   SettingsView().toolbar { ConsoleToolbarItems() }
        case .roster:  ServerRosterView()
        case .admin:   AdminConsoleView()
        }
    }
}

extension EnvironmentValues {
    /// Экран показан в консоли. Отдельное окно логов — нет: там чипа и
    /// главной кнопки не нужно.
    @Entry var gsInConsole = false
}

/// Чип профиля и «Подключить / Отключить» — последними в тулбаре любой
/// вкладки, чтобы главная кнопка всегда стояла справа и не прыгала. Без
/// профилей обоих нет: подключать нечего.
struct ConsoleToolbarItems: ToolbarContent {
    @Environment(\.gsInConsole) private var inConsole
    @Environment(ProfilesStore.self) private var profiles

    var body: some ToolbarContent {
        if inConsole && !profiles.profiles.isEmpty {
            if #available(macOS 26, *) {
                // Чип — своей капсулой, отдельно от кнопок экрана.
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItem(placement: .primaryAction) {
                ProfileChip()
            }
            ToolbarItem(placement: .primaryAction) {
                ConnectButton()
            }
            .gsOwnBackground()
        }
    }
}
