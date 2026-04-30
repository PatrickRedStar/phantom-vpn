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

    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "AppDelegate")

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
