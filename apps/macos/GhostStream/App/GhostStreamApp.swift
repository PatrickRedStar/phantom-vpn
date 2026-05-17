//
//  GhostStreamApp.swift
//  GhostStream (macOS)
//
//  @main entry. Hosts a `MenuBarExtra` (primary surface), a single
//  singleton `Window` for the main console, plus a separate window for the
//  Welcome / onboarding panel and the standard `Settings` scene.
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

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    @Environment(\.openWindow) private var openWindow

    @State private var profiles = ProfilesStore.shared
    @State private var prefs    = PreferencesStore.shared
    @State private var state    = VpnStateManager.shared
    @State private var router   = AppRouter.shared
    @State private var sysExt   = SystemExtensionInstaller.shared
    @State private var login    = LoginItemController.shared
    @State private var dock     = DockPolicyController.shared
    @State private var upstream = UpstreamVpnMonitor.shared
    @State private var traffic  = TrafficSeriesStore.shared
    @State private var logs     = TunnelLogStore.shared
    @State private var notifications = VpnNotificationController.shared

    @State private var tunnel = VpnTunnelController()
    @State private var startupHandled = false

    var body: some Scene {
        // Primary surface — menu bar.
        MenuBarExtra {
            MenuBarPopover()
                .environment(profiles)
                .environment(prefs)
                .environment(state)
                .environment(router)
                .environment(sysExt)
                .environment(dock)
                .environment(upstream)
                .environment(traffic)
                .environment(logs)
                .environmentObject(tunnel)
                .gsTheme(override: themeOverride(from: prefs.theme))
                .frame(width: 380, height: 520)
        } label: {
            MenuBarStatusItem(state: state.statusFrame.state)
                .task {
                    notifications.configure()
                    await openSetupIfNeeded()
                    upstream.start(profiles: profiles, preferences: prefs, stateManager: state)
                    traffic.start(stateManager: state)
                    logs.start(stateManager: state)
                }
                .onChange(of: notificationToken(from: state.statusFrame)) { _, _ in
                    notifications.handle(frame: state.statusFrame, preferences: prefs)
                }
                .onChange(of: prefs.notifyStateChanges) { _, _ in
                    notifications.requestAuthorizationIfNeeded(preferences: prefs)
                }
        }
        .menuBarExtraStyle(.window)

        // Main console window.
        Window("GhostStream", id: "console") {
            ForegroundWindowClaim("console", dock: dock) {
                MainConsoleWindow()
                    .environment(profiles)
                    .environment(prefs)
                    .environment(state)
                    .environment(router)
                    .environment(sysExt)
                    .environment(login)
                    .environment(dock)
                    .environment(upstream)
                    .environment(traffic)
                    .environment(logs)
                    .environmentObject(tunnel)
                    .gsTheme(override: themeOverride(from: prefs.theme))
                    .frame(minWidth: 960, minHeight: 640)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "menu.about")) {
                    openForegroundWindow("about")
                }
            }
            // ⌘0 — focus / open the main console window.
            CommandGroup(after: .windowArrangement) {
                Button(String(localized: "menu.open_console")) {
                    openForegroundWindow("console")
                }
                .keyboardShortcut("0", modifiers: .command)

                Button(String(localized: "command_palette.placeholder")) {
                    openForegroundWindow("console")
                    router.commandPaletteOpen = true
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Open Logs") {
                    router.openDetachedLogs()
                    openForegroundWindow("logs")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        // Detached logs window, opened from the command palette or ⇧⌘L.
        Window("Logs", id: "logs") {
            ForegroundWindowClaim("logs", dock: dock) {
                TailView()
                    .environment(prefs)
                    .environment(state)
                    .environment(logs)
                    .gsTheme(override: themeOverride(from: prefs.theme))
                    .frame(minWidth: 760, minHeight: 520)
                    .onAppear { router.detachedLogsOpen = true }
                    .onDisappear { router.detachedLogsOpen = false }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // Onboarding window.
        Window("Welcome", id: "welcome") {
            ForegroundWindowClaim("welcome", dock: dock) {
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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Custom About panel — wired to the App-menu "About" item via
        // CommandGroup(replacing: .appInfo).
        Window("About", id: "about") {
            ForegroundWindowClaim("about", dock: dock) {
                AboutView()
                    .gsTheme(override: themeOverride(from: prefs.theme))
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Standard Settings scene → CMD-,
        Settings {
            ForegroundWindowClaim("settings", dock: dock) {
                SettingsView()
                    .environment(prefs)
                    .environment(profiles)
                    .environment(state)
                    .environment(logs)
                    .environment(login)
                    .environment(dock)
                    .environment(upstream)
                    .gsTheme(override: themeOverride(from: prefs.theme))
                    .frame(minWidth: 520, minHeight: 480)
            }
        }
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
            startInMenuBar: prefs.startInMenuBar
        )

        if decision.shouldActivateSystemExtension {
            sysExt.activate()
        }

        switch decision.foregroundWindow {
        case .welcome:
            openForegroundWindow("welcome")
        case .none:
            break
        }
    }

    @MainActor
    private func openForegroundWindow(_ id: String) {
        openWindow(id: id)
        dock.activateForegroundWindow()
    }

    private func isGhostStreamManagerConfigured(_ manager: NETunnelProviderManager?) -> Bool {
        guard let manager,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        else { return false }

        return proto.providerBundleIdentifier == "com.ghoststream.client.tunnel" && manager.isEnabled
    }

    private func notificationToken(from frame: StatusFrame) -> String {
        [
            frame.state.rawValue,
            frame.reconnectAttempt.map(String.init) ?? "",
            frame.reconnectNextDelaySecs.map(String.init) ?? "",
            frame.lastError ?? "",
        ].joined(separator: "|")
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

@MainActor
private final class VpnNotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = VpnNotificationController()

    private var configured = false
    private var previousFrame: StatusFrame?

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
        configure()
        let notification = VpnStateNotificationPolicy.notification(
            previous: previousFrame,
            current: frame,
            enabled: preferences.notifyStateChanges
        )
        previousFrame = frame

        guard let notification else { return }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "ghoststream.state.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
