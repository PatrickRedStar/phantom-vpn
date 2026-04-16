//
//  GhostStreamApp.swift
//  GhostStream
//
//  @main entry point. Wires the three observable singletons into the
//  SwiftUI environment and applies the Ghoststream theme + colour scheme.
//

import SwiftUI

/// App entry point. Hosts the root `AppNavigation` and injects:
/// - `ProfilesStore` — VPN profiles + active selection
/// - `PreferencesStore` — DNS / routing / theme / locale prefs
/// - `VpnStateManager` — cross-process VPN state
///
/// Theme: reads `PreferencesStore.theme` (`"system"` / `"dark"` / `"light"`)
/// and forwards to the `gsTheme()` modifier, which resolves both the
/// palette (`\.gsColors`) and the system `.preferredColorScheme`.
@main
struct GhostStreamApp: App {

    /// Singleton, main-actor-bound observable store for profiles.
    @State private var profiles = ProfilesStore.shared

    /// Singleton, main-actor-bound observable store for global prefs.
    @State private var prefs = PreferencesStore.shared

    /// Singleton, main-actor-bound observable VPN state.
    @State private var state = VpnStateManager.shared

    var body: some Scene {
        WindowGroup {
            AppNavigation()
                .environment(profiles)
                .environment(prefs)
                .environment(state)
                .gsTheme(override: themeOverride(from: prefs.theme))
        }
    }

    /// Map the string stored in `PreferencesStore.theme` to a
    /// `ThemeOverride`. Unknown values fall back to `.system`.
    private func themeOverride(from raw: String) -> ThemeOverride {
        ThemeOverride(rawValue: raw) ?? .system
    }
}
