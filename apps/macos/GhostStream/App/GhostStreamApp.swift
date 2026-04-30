//
//  GhostStreamApp.swift
//  GhostStream (macOS)
//
//  @main entry. Hosts a `MenuBarExtra` (primary surface), a single
//  `WindowGroup` for the main console, plus a separate window for the
//  Welcome / onboarding panel and the standard `Settings` scene.
//
//  Singletons (ProfilesStore / PreferencesStore / VpnStateManager /
//  AppRouter) are passed via `.environment` so any view can read them.
//

import PhantomKit
import PhantomUI
import NetworkExtension
import SwiftUI

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
                .environment(upstream)
                .environmentObject(tunnel)
                .gsTheme(override: themeOverride(from: prefs.theme))
                .frame(width: 380, height: 520)
        } label: {
            MenuBarStatusItem(state: state.statusFrame.state)
                .task {
                    await openSetupIfNeeded()
                    upstream.start(profiles: profiles, preferences: prefs, stateManager: state)
                }
        }
        .menuBarExtraStyle(.window)

        // Main console window.
        WindowGroup(id: "console") {
            MainConsoleWindow()
                .environment(profiles)
                .environment(prefs)
                .environment(state)
                .environment(router)
                .environment(sysExt)
                .environment(login)
                .environment(dock)
                .environment(upstream)
                .environmentObject(tunnel)
                .gsTheme(override: themeOverride(from: prefs.theme))
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(String(localized: "menu.about")) {
                    openWindow(id: "about")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            // ⌘0 — focus / open the main console window.
            CommandGroup(after: .windowArrangement) {
                Button(String(localized: "menu.open_console")) {
                    openWindow(id: "console")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button(String(localized: "command_palette.placeholder")) {
                    openWindow(id: "console")
                    NSApp.activate(ignoringOtherApps: true)
                    router.commandPaletteOpen = true
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Open Logs") {
                    router.openDetachedLogs()
                    openWindow(id: "logs")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        // Detached logs window, opened from the command palette or ⇧⌘L.
        Window("Logs", id: "logs") {
            TailView()
                .environment(state)
                .gsTheme(override: themeOverride(from: prefs.theme))
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { router.detachedLogsOpen = true }
                .onDisappear { router.detachedLogsOpen = false }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        // Onboarding window.
        Window("Welcome", id: "welcome") {
            WelcomeWindow()
                .environment(profiles)
                .environment(prefs)
                .environment(sysExt)
                .environment(upstream)
                .environmentObject(tunnel)
                .gsTheme(override: themeOverride(from: prefs.theme))
                .frame(width: 720, height: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Custom About panel — wired to the App-menu "About" item via
        // CommandGroup(replacing: .appInfo).
        Window("About", id: "about") {
            AboutView()
                .gsTheme(override: themeOverride(from: prefs.theme))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Standard Settings scene → CMD-,
        Settings {
            SettingsView()
                .environment(prefs)
                .environment(profiles)
                .environment(login)
                .environment(dock)
                .environment(upstream)
                .gsTheme(override: themeOverride(from: prefs.theme))
                .frame(minWidth: 520, minHeight: 480)
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
        if isGhostStreamManagerConfigured(tunnel.manager) {
            sysExt.activate()
            return
        }

        if profiles.activeProfile != nil {
            sysExt.activate()
        }
        openWindow(id: "welcome")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func isGhostStreamManagerConfigured(_ manager: NETunnelProviderManager?) -> Bool {
        guard let manager,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        else { return false }

        return proto.providerBundleIdentifier == "com.ghoststream.vpn.tunnel" && manager.isEnabled
    }
}
