//
//  DockPolicyController.swift
//  GhostStream (macOS)
//
//  Toggles `NSApp.activationPolicy` between `.regular` (Dock-visible) and
//  `.accessory` (menu-bar-only). Persists to App Group UserDefaults so the
//  pref survives relaunch.
//

import AppKit
import Foundation
import Observation

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
        self.defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")!
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
}
