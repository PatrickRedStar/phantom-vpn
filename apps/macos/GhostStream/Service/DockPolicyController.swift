//
//  DockPolicyController.swift
//  GhostStream (macOS)
//
//  Toggles `NSApp.activationPolicy` between `.regular` (Dock-visible /
//  foreground windows) and `.accessory` (menu-bar-only). Persists to App Group
//  UserDefaults so the pref survives relaunch.
//

import AppKit
import Foundation
import Observation
import os.log

@MainActor
@Observable
public final class DockPolicyController {

    public static let shared = DockPolicyController()

    public var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Self.key)
            apply()
        }
    }

    private let defaults: UserDefaults
    private static let key = "showInDock"

    private init() {
        // App Group lookup can fail when entitlements are broken; the host
        // would then trap before reaching any UI. Fall back to standard
        // UserDefaults so the Dock policy still works locally even if the
        // pref no longer survives across containers.
        if let suite = UserDefaults(suiteName: "group.com.ghoststream.client") {
            self.defaults = suite
        } else {
            Logger(subsystem: "com.ghoststream.client", category: "dock")
                .fault("App Group container unavailable, falling back to standard UserDefaults (Dock pref will not sync)")
            self.defaults = UserDefaults.standard
        }
        // Default = true (Dock visible); user can hide via Settings.
        if defaults.object(forKey: Self.key) == nil {
            self.showInDock = true
        } else {
            self.showInDock = defaults.bool(forKey: Self.key)
        }
    }

    public func apply() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    public func foregroundWindowDidAppear(_: String) {
        apply()
    }

    public func foregroundWindowDidDisappear(_: String) {
        apply()
    }

    public func activateForegroundWindow() {
        apply()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
