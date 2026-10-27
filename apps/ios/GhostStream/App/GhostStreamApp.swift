//
//  GhostStreamApp.swift
//  GhostStream
//
//  @main entry point. Wires the three observable singletons into the
//  SwiftUI environment and applies the Ghoststream theme + colour scheme.
//

import Foundation
import PhantomKit
import PhantomUI
import SwiftUI
import UIKit

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

    init() {
        PhantomUIResources.registerFonts()
        // Native navigation titles in the brand face (mockups: Space Grotesk).
        let nav = UINavigationBar.appearance()
        if let large = UIFont(name: GsFontName.spaceGroteskBold, size: 34),
           let inline = UIFont(name: GsFontName.spaceGroteskBold, size: 17) {
            nav.largeTitleTextAttributes = [.font: large]
            nav.titleTextAttributes = [.font: inline]
        }
        #if DEBUG
        DebugDemo.startIfRequested()
        #endif
        // Starts reloading the widget / control when their labels change.
        _ = SystemSurfaces.shared
    }

    var body: some Scene {
        WindowGroup {
            AppNavigation()
                .environment(profiles)
                .environment(prefs)
                .environment(state)
                .environment(\.locale, appLocale(from: prefs.languageOverride))
                .gsTheme(override: themeOverride(from: prefs.theme))
        }
    }

    /// Map the string stored in `PreferencesStore.theme` to a
    /// `ThemeOverride`. Unknown values fall back to `.system`.
    private func themeOverride(from raw: String) -> ThemeOverride {
        ThemeOverride(rawValue: raw) ?? .system
    }

    /// Resolve the saved language override for SwiftUI localization. Missing,
    /// blank, or explicit "system" values follow the current system locale.
    private func appLocale(from raw: String?) -> Locale {
        guard let raw,
              !raw.isEmpty,
              raw != "system"
        else {
            return .autoupdatingCurrent
        }

        return Locale(identifier: raw)
    }
}

enum AppStrings {
    private static let languageKey = "language_override"
    private static let appGroup = "group.com.ghoststream.client"

    /// UI language is English — for text built in code (ConnectErrorHumanizer).
    static var isEnglish: Bool {
        (languageOverride ?? Bundle.main.preferredLocalizations.first ?? "ru").hasPrefix("en")
    }

    private static var languageOverride: String? {
        guard let code = UserDefaults(suiteName: appGroup)?
            .string(forKey: languageKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty, code != "system"
        else { return nil }
        return code
    }

    static func localized(_ key: String, fallback: String? = nil) -> String {
        let bundle = localizedBundle(for: languageOverride)
        return NSLocalizedString(
            key,
            tableName: nil,
            bundle: bundle,
            value: fallback ?? key,
            comment: ""
        )
    }

    private static func localizedBundle(for override: String?) -> Bundle {
        guard let override,
              let path = Bundle.main.path(forResource: override, ofType: "lproj"),
              let bundle = Bundle(path: path)
        else {
            return .main
        }
        return bundle
    }
}
