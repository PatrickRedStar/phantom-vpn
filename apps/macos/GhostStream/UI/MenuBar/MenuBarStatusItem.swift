//
//  MenuBarStatusItem.swift
//  GhostStream (macOS)
//
//  Menu bar label — uses the brand `MenuBarIcon` asset (rendered from
//  `icons/v4-03-scope/ic_launcher_monochrome.svg` at 18/36/54 px) marked
//  as a template image so macOS auto-tints it to match the system menu
//  bar foreground (black on light, white on dark). A small coloured dot
//  beside the glyph reflects the current `ConnState` — macOS 14+ keeps
//  custom-colour SwiftUI shapes inside menu bar labels.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct MenuBarStatusItem: View {

    public let state: ConnState

    public init(state: ConnState) {
        self.state = state
    }

    /// UI-R2-R08: the menu bar label runs outside the SwiftUI
    /// environment chain that provides `\.gsColors`, so we look up the
    /// palette manually. Round 1 hard-coded `.dark` which left the
    /// state dot at dark-mode values when the user had explicitly
    /// switched to the light theme — most visible as the wrong shade
    /// of green for the "connected" dot on a light menu bar.
    ///
    /// UI-R4-R01: keep reactivity to runtime theme changes. The Round 2
    /// fix read `ThemeOverride.current` — a static computed property
    /// backed by UserDefaults. SwiftUI has no dependency on that read,
    /// so flipping the theme in Settings did not invalidate the body.
    /// We now read `prefs.theme` through the @Observable
    /// `PreferencesStore.shared` singleton, which SwiftUI tracks via
    /// the Observation framework — so the menu bar palette refreshes
    /// the moment the user toggles Light/Dark/System.
    @Environment(\.colorScheme) private var systemScheme

    /// `@State` holding the shared singleton — SwiftUI installs
    /// Observation tracking on every property read inside `body`, so
    /// `prefs.theme` becomes a real dependency without us needing to
    /// pipe `PreferencesStore` through the environment (which the
    /// `MenuBarExtra` label view does not get on macOS 14).
    @State private var prefs = PreferencesStore.shared

    private var palette: GsColorSet {
        switch ThemeOverride(rawValue: prefs.theme) ?? .system {
        case .dark:   return .dark
        case .light:  return .light
        case .system: return systemScheme == .light ? .light : .dark
        }
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 18, height: 18)
            stateDot
        }
        .accessibilityLabel("GhostStream — \(accessibilityState)")
    }

    @ViewBuilder
    private var stateDot: some View {
        switch state {
        case .connected:
            Circle()
                .fill(palette.signal)
                .frame(width: 5, height: 5)
        case .connecting, .reconnecting:
            Circle()
                .fill(palette.warn)
                .frame(width: 5, height: 5)
        case .error:
            Circle()
                .fill(palette.danger)
                .frame(width: 5, height: 5)
        case .disconnected:
            EmptyView()
        }
    }

    private var accessibilityState: String {
        switch state {
        case .disconnected: return "Standby"
        case .connecting:   return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .connected:    return "Transmitting"
        case .error:        return "Error"
        }
    }
}

#Preview("MenuBarStatusItem") {
    HStack(spacing: 24) {
        MenuBarStatusItem(state: .disconnected)
        MenuBarStatusItem(state: .connecting)
        MenuBarStatusItem(state: .connected)
        MenuBarStatusItem(state: .error)
    }
    .padding()
    .background(Color.gray)
}
