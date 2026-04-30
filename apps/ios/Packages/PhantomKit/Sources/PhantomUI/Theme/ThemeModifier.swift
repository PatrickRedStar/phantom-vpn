//
//  ThemeModifier.swift
//  GhostStream
//
//  Reads the user's theme choice from the shared App Group
//  UserDefaults(suiteName: "group.com.ghoststream.vpn") — key "theme" —
//  and resolves it to a GsColorSet (environment) + .preferredColorScheme.
//
//  Usage:
//      @main struct GhostStreamApp: App {
//          var body: some Scene {
//              WindowGroup { RootView().gsTheme() }
//          }
//      }
//

import SwiftUI

// MARK: - Theme override

/// Three-state override persisted to shared UserDefaults.
/// Raw values are the strings written by the Android app / widgets so a single
/// key survives cross-platform share-targets.
public enum ThemeOverride: String, CaseIterable {
    case system = "system"
    case dark   = "dark"
    case light  = "light"

    public static let userDefaultsKey = "theme"
    public static let appGroupSuite   = "group.com.ghoststream.vpn"

    /// Read the current persisted value; falls back to `.system` on missing /
    /// unrecognised input.
    public static var current: ThemeOverride {
        guard
            let defaults = UserDefaults(suiteName: appGroupSuite),
            let raw = defaults.string(forKey: userDefaultsKey),
            let parsed = ThemeOverride(rawValue: raw)
        else {
            return .system
        }
        return parsed
    }

    /// Write-through helper for Settings UI.
    public static func set(_ value: ThemeOverride) {
        UserDefaults(suiteName: appGroupSuite)?.set(value.rawValue, forKey: userDefaultsKey)
    }

    /// SwiftUI colour-scheme preference; `nil` means "follow system".
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }
}

// MARK: - GsTheme view modifier

/// Applies the resolved Ghoststream palette via `\.gsColors` and forces the
/// matching `preferredColorScheme`. Re-reads UserDefaults when `override` flips.
public struct GsTheme: ViewModifier {
    /// Explicit override from caller. `nil` → read from UserDefaults (App Group).
    public var override: ThemeOverride?

    public init(override: ThemeOverride? = nil) {
        self.override = override
    }

    @Environment(\.colorScheme) private var systemScheme

    private var resolved: ThemeOverride {
        override ?? ThemeOverride.current
    }

    private var palette: GsColorSet {
        switch resolved {
        case .dark:   return .dark
        case .light:  return .light
        case .system: return systemScheme == .light ? .light : .dark
        }
    }

    public func body(content: Content) -> some View {
        content
            .environment(\.gsColors, palette)
            .preferredColorScheme(resolved.preferredColorScheme)
    }
}

extension View {
    /// Apply the Ghoststream theme, optionally forcing a specific override.
    /// When `override` is `nil`, reads the user's saved choice from the shared
    /// App Group UserDefaults (`group.com.ghoststream.vpn`, key `"theme"`).
    public func gsTheme(override: ThemeOverride? = nil) -> some View {
        modifier(GsTheme(override: override))
    }
}
