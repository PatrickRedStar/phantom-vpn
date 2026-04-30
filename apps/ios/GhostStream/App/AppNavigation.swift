//
//  AppNavigation.swift
//  GhostStream
//
//  Root tab container. Three tabs (Dashboard / Logs / Settings), each
//  wrapped in its own NavigationStack so pushes (e.g. Settings → Admin)
//  don't leak between tabs. Admin is NOT a tab — it's pushed from Settings.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Tab identifier for the native tab bar.
enum AppTab: Int, CaseIterable, Hashable {
    case dashboard
    case logs
    case settings

    /// Short label shown in the tab bar.
    var label: String {
        switch self {
        case .dashboard: return NSLocalizedString("nav_stream", value: "Stream", comment: "")
        case .logs:      return NSLocalizedString("nav_logs", value: "Logs", comment: "")
        case .settings:  return NSLocalizedString("nav_settings", value: "Settings", comment: "")
        }
    }

    var systemImageName: String {
        switch self {
        case .dashboard: return "waveform.path.ecg"
        case .logs:      return "doc.text.magnifyingglass"
        case .settings:  return "gearshape"
        }
    }

    var accessibilityLabel: String {
        label
    }
}

/// Root of the app UI. Admin is intentionally not a tab; it is opened from
/// an admin-capable profile detail screen.
struct AppNavigation: View {

    @Environment(\.gsColors) private var C
    @State private var selection: AppTab = .dashboard

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DashboardView()
            }
            .tabItem {
                Label(AppTab.dashboard.label, systemImage: AppTab.dashboard.systemImageName)
            }
            .tag(AppTab.dashboard)

            NavigationStack {
                LogsView()
            }
            .tabItem {
                Label(AppTab.logs.label, systemImage: AppTab.logs.systemImageName)
            }
            .tag(AppTab.logs)

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(AppTab.settings.label, systemImage: AppTab.settings.systemImageName)
            }
            .tag(AppTab.settings)
        }
        .tint(C.signal)
        .toolbarBackground(C.bg, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

// MARK: - Preview

#Preview("AppNavigation") {
    AppNavigation()
        .environment(ProfilesStore.shared)
        .environment(PreferencesStore.shared)
        .environment(VpnStateManager.shared)
        .gsTheme(override: .dark)
}
