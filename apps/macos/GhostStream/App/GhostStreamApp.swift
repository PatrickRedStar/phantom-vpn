//
//  GhostStreamApp.swift
//  GhostStream (macOS)
//
//  @main entry. Hosts a `MenuBarExtra` (primary surface), a single
//  singleton `Window` for the main console (⌘, opens it on «Настройки»),
//  plus separate windows for logs, Welcome / onboarding and About.
//
//  Singletons (ProfilesStore / PreferencesStore / VpnStateManager /
//  AppRouter) are passed via `.environment` so any view can read them.
//

import PhantomKit
import PhantomUI
import Foundation
import NetworkExtension
import SwiftUI
import UserNotifications

@main
struct GhostStreamApp: App {

    #if DEBUG
    // Первым полем: демо-данные подставляются до создания сторов ниже.
    private let demo: Void = DebugDemo.prepare()
    #endif

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @Environment(\.openWindow) private var openWindow

    @State private var profiles = ProfilesStore.shared
    @State private var prefs    = PreferencesStore.shared
    @State private var state    = VpnStateManager.shared
    @State private var router   = AppRouter.shared
    @State private var sysExt   = SystemExtensionInstaller.shared
    @State private var dock     = DockPolicyController.shared
    @State private var upstream = UpstreamVpnMonitor.shared
    @State private var traffic  = TrafficSeriesStore.shared
    @State private var logs     = TunnelLogStore.shared
    @State private var notifications = VpnNotificationController.shared

    @State private var tunnel = VpnTunnelController.shared
    @State private var startupHandled = false

    var body: some Scene {
        // Primary surface — menu bar.
        MenuBarExtra {
            LocalizedRoot {
                // Размер — по содержимому (FitWindowToContent в попапе).
                MenuBarPopover()
                    .gsAppEnvironment()
            }
        } label: {
            MenuBarStatusItem(state: state.statusFrame.state)
                .task {
                    delegate.openConsole = { openForegroundWindow("console") }
                    #if DEBUG
                    if DebugDemo.isActive {
                        await DebugDemo.start { openForegroundWindow("console") }
                        return
                    }
                    #endif
                    notifications.configure()
                    await openSetupIfNeeded()
                    upstream.start(profiles: profiles, preferences: prefs, stateManager: state)
                    traffic.start(stateManager: state)
                    logs.start(stateManager: state)
                }
                .onChange(of: state.statusFrame.state) { _, _ in
                    notifications.handle(frame: state.statusFrame, preferences: prefs)
                }
                .onChange(of: prefs.notifyStateChanges) { _, _ in
                    notifications.requestAuthorizationIfNeeded(preferences: prefs)
                }
                // Смена/удаление активного профиля из любого места UI при
                // поднятом туннеле — переподключение в одной точке.
                .onChange(of: profiles.activeProfile?.id) { oldId, _ in
                    tunnel.activeProfileChanged(from: oldId, profiles: profiles, preferences: prefs)
                }
        }
        .menuBarExtraStyle(.window)

        // Main console window.
        Window("GhostStream", id: "console") {
            ForegroundWindowClaim("console", dock: dock) {
                LocalizedRoot {
                MainConsoleWindow()
                    // Подсказка после мастера; до gsAppEnvironment — ей нужны тема и цвета.
                    .overlay(alignment: .bottom) { MenuBarHint() }
                    .gsAppEnvironment()
                }
            }
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(L("menu.about")) {
                    openForegroundWindow("about")
                }
            }
            // ⌘, — консоль на «Настройках» вместо отдельного окна настроек.
            CommandGroup(replacing: .appSettings) {
                Button(L("menu.settings")) {
                    openConsole(on: .setup)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // ⌘1…⌘5 — пункты сайдбара (меню «Вид»). Пока открыта палитра,
            // цифры нужны её полю поиска.
            CommandGroup(before: .sidebar) {
                ForEach(SidebarChannel.visible(adminUnlocked: profiles.activeProfile?.cachedIsAdmin == true)) { channel in
                    Button(L(channel.localizedKey)) {
                        openConsole(on: channel)
                    }
                    .keyboardShortcut(KeyEquivalent(channel.hotkey), modifiers: .command)
                }
                .disabled(router.commandPaletteOpen)
                Divider()
            }
            // ⌘0 — focus / open the main console window.
            CommandGroup(after: .windowArrangement) {
                Button(L("menu.open_console")) {
                    openForegroundWindow("console")
                }
                .keyboardShortcut("0", modifiers: .command)

                // UI-R2-R09: was `command_palette.placeholder`
                // ("Введите команду или профиль…") — the *placeholder*
                // string was reused for the menu item title, so the
                // menu read like a search prompt instead of an action.
                Button(L("menu.command_palette")) {
                    openForegroundWindow("console")
                    router.commandPaletteOpen = true
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                // UI-R2-R10: was hardcoded English — broke the menu
                // on RU locale (mixed RU/EN strings).
                Button(L("menu.logs")) {
                    router.openDetachedLogs()
                    openForegroundWindow("logs")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        // Detached logs window, opened from the command palette or ⇧⌘L.
        Window(L("menu.logs"), id: "logs") {
            ForegroundWindowClaim("logs", dock: dock) {
                LocalizedRoot {
                TailView()
                    .environment(prefs)
                    .environment(state)
                    .environment(logs)
                    .environment(router)
                    .gsTheme(override: themeOverride(from: prefs.theme))
                    .frame(minWidth: 760, minHeight: 520)
                    .onAppear { router.detachedLogsOpen = true }
                    .onDisappear { router.detachedLogsOpen = false }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // Onboarding window.
        Window(L("welcome.window_title"), id: "welcome") {
            ForegroundWindowClaim("welcome", dock: dock) {
                LocalizedRoot {
                WelcomeWindow()
                    .environment(profiles)
                    .environment(prefs)
                    .environment(sysExt)
                    .environment(upstream)
                    .environmentObject(tunnel)
                    .gsTheme(override: themeOverride(from: prefs.theme))
                    .frame(width: 720, height: 560)
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Custom About panel — wired to the App-menu "About" item via
        // CommandGroup(replacing: .appInfo).
        Window(L("menu.about"), id: "about") {
            ForegroundWindowClaim("about", dock: dock) {
                LocalizedRoot {
                AboutView()
                    .gsTheme(override: themeOverride(from: prefs.theme))
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

    }

    private func themeOverride(from raw: String) -> ThemeOverride {
        ThemeOverride(rawValue: raw) ?? .system
    }

    @MainActor
    private func openSetupIfNeeded() async {
        guard !startupHandled else { return }
        startupHandled = true

        try? await tunnel.loadFromPreferences()
        let decision = MacStartupPolicy.decide(
            managerConfigured: isGhostStreamManagerConfigured(tunnel.manager),
            hasActiveProfile: profiles.activeProfile != nil,
            startInMenuBar: prefs.startInMenuBar,
            launchedAtLogin: AppDelegate.launchedAtLogin
        )

        if decision.shouldActivateSystemExtension {
            sysExt.activate()
        }

        switch decision.foregroundWindow {
        case .welcome:
            openForegroundWindow("welcome")
        case .console:
            openForegroundWindow("console")
        case .none:
            break
        }
    }

    @MainActor
    private func openForegroundWindow(_ id: String) {
        openWindow(id: id)
        dock.activateForegroundWindow()
    }

    @MainActor
    private func openConsole(on channel: SidebarChannel) {
        router.select(channel)
        openForegroundWindow("console")
    }

    private func isGhostStreamManagerConfigured(_ manager: NETunnelProviderManager?) -> Bool {
        guard let manager,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        else { return false }

        return proto.providerBundleIdentifier == "com.ghoststream.client.tunnel" && manager.isEnabled
    }
}

extension View {
    /// Синглтоны приложения для консоли, попапа меню-бара и DEBUG-снимков.
    @MainActor
    func gsAppEnvironment() -> some View {
        environment(ProfilesStore.shared)
            .environment(PreferencesStore.shared)
            .environment(VpnStateManager.shared)
            .environment(AppRouter.shared)
            .environment(SystemExtensionInstaller.shared)
            .environment(LoginItemController.shared)
            .environment(DockPolicyController.shared)
            .environment(UpstreamVpnMonitor.shared)
            .environment(TrafficSeriesStore.shared)
            .environment(TunnelLogStore.shared)
            .environment(UpdateChecker.shared)
            .environmentObject(VpnTunnelController.shared)
            .gsTheme(override: ThemeOverride(rawValue: PreferencesStore.shared.theme) ?? .system)
    }
}

private struct ForegroundWindowClaim<Content: View>: View {
    private let windowID: String
    private let dock: DockPolicyController
    private let content: Content

    @State private var claimID = UUID().uuidString

    init(_ windowID: String, dock: DockPolicyController, @ViewBuilder content: () -> Content) {
        self.windowID = windowID
        self.dock = dock
        self.content = content()
    }

    var body: some View {
        content
            .onAppear {
                dock.foregroundWindowDidAppear("\(windowID):\(claimID)")
            }
            .onDisappear {
                dock.foregroundWindowDidDisappear("\(windowID):\(claimID)")
            }
    }
}

/// Уровень уведомлений в «Настройках». Выключены = `notifyStateChanges`
/// false; «обо всех» — отдельный флаг macOS (iOS его не знает).
enum NotifyLevel: Hashable {
    case problems, all, off

    static let allKey = "notifyAllStateChanges"
}

/// Системные уведомления macOS (по-русски через `L()`). Общую с iOS
/// `VpnStateNotificationPolicy` не используем: здесь другие правила —
/// без ручного отключения и без коротких переподключений.
@MainActor
private final class VpnNotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = VpnNotificationController()

    /// Переподключение короче этого не беспокоит (смена Wi‑Fi, сон).
    private static let lostDelay: Duration = .seconds(10)

    private var configured = false
    private var previousState: ConnState?
    private var lostTask: Task<Void, Never>?
    /// Уже сказали «нет связи» — на восстановление скажем «восстановлено».
    private var lostNotified = false

    func configure() {
        guard !configured else { return }
        UNUserNotificationCenter.current().delegate = self
        configured = true
    }

    func requestAuthorizationIfNeeded(preferences: PreferencesStore) {
        guard preferences.notifyStateChanges else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func handle(frame: StatusFrame, preferences: PreferencesStore) {
        #if DEBUG
        if DebugDemo.isActive { return }
        #endif
        configure()
        let previous = previousState
        previousState = frame.state
        // Первый кадр после запуска — не переход.
        guard let previous, previous != frame.state else { return }
        if frame.state != .reconnecting {
            lostTask?.cancel()
            lostTask = nil
        }
        guard preferences.notifyStateChanges else {
            lostNotified = false
            return
        }
        let profile = ProfilesStore.shared.activeProfile?.name ?? "GhostStream"

        switch frame.state {
        case .reconnecting:
            lostTask = Task { [weak self] in
                try? await Task.sleep(for: Self.lostDelay)
                guard let self, !Task.isCancelled, self.previousState == .reconnecting else { return }
                self.lostNotified = true
                self.post(title: L("notify.lost.title"), body: L("notify.lost.body"))
            }
        case .connected:
            if lostNotified {
                post(title: L("notify.restored.title"),
                     body: String(format: L("notify.restored.body"), profile))
            } else if previous == .connecting, UserDefaults.standard.bool(forKey: NotifyLevel.allKey) {
                post(title: L("notify.connected.title"), body: profile)
            }
            lostNotified = false
        case .error:
            // Фатальная остановка: причина в заголовке, что делать — в тексте.
            let text = ConnectErrorHumanizer.fatalStop(
                frame.lastError ?? "",
                profileName: profile,
                english: !Self.isRussianUI
            )
            post(title: text.title, body: text.body)
            lostNotified = false
        case .disconnected, .connecting:
            // Отключение без ошибки — это пользователь сам; он и так знает.
            lostNotified = false
        }
    }

    private static var isRussianUI: Bool {
        (LocalizationManager.shared.language ?? Bundle.main.preferredLocalizations.first ?? "ru")
            .hasPrefix("ru")
    }

    /// NOTIF-1: авторизацию запрашиваем только если она ещё не определена.
    private func post(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Self.add(title: title, body: body)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Self.add(title: title, body: body) }
                }
            default:
                return
            }
        }
    }

    nonisolated private static func add(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "ghoststream.state.\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
