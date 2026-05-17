//
//  AppDelegate.swift
//  GhostStream (macOS)
//
//  NSApplicationDelegate hooks: registers PhantomUI fonts, applies the
//  initial dock activation policy, and bootstraps the system extension
//  install request on first launch.
//

import AppKit
import Foundation
import os.log

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let log = Logger(subsystem: "com.ghoststream.client", category: "AppDelegate")

    /// SwiftUI 14+: `applicationWillFinishLaunching(_:)` is called BEFORE
    /// the App's `body` is first evaluated — so any singletons that the
    /// scene captures via `@State` (ProfilesStore.shared, PreferencesStore.shared,
    /// VpnStateManager.shared, …) initialise *after* this hook returns.
    ///
    /// We run the v0.23 → v0.24 legacy migration's synchronous phase here
    /// so the ProfilesStore.init() that fires from `GhostStreamApp.body`
    /// reads the migrated `profiles.json` on its very first `load()`
    /// instead of seeing an empty UserDefaults and then clobbering the
    /// migrated data on the next `save()` (OPS-R2-04 / SEC-R2-N01 — see
    /// docs/knowledge/audits/2026-05-17-macos-bug-hunt-round2.md).
    ///
    /// The slow phase of the migration (Keychain re-import, file copies,
    /// NETunnelProviderManager prune) is dispatched onto a detached task
    /// from `LegacyMigration.runIfNeeded()` so the UI launch isn't
    /// blocked by Keychain enumeration (CONC-R2-N10).
    func applicationWillFinishLaunching(_ notification: Notification) {
        LegacyMigration.runIfNeeded()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Programmatic font registration — UIAppFonts is iOS-only.
        FontRegistration.register()

        // Initial Dock policy.
        DockPolicyController.shared.apply()

        log.info("GhostStream launched (macOS)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.info("GhostStream terminating")
    }

    /// Re-open the main window when the user clicks the Dock tile after
    /// the window has been closed.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            for window in sender.windows {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }

    /// Don't terminate when the last window is closed — the menu-bar
    /// extra is the primary surface.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
