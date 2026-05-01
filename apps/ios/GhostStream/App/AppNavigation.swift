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
import os.log

/// Tab identifier for the native tab bar.
enum AppTab: Int, CaseIterable, Hashable {
    case dashboard
    case logs
    case settings

    /// Short label shown in the tab bar.
    var label: String {
        switch self {
        case .dashboard: return AppStrings.localized("nav_stream", fallback: "Stream")
        case .logs:      return AppStrings.localized("nav_logs", fallback: "Logs")
        case .settings:  return AppStrings.localized("nav_settings", fallback: "Settings")
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
    @Environment(ProfilesStore.self) private var profiles
    @Environment(PreferencesStore.self) private var prefs
    @State private var selection: AppTab = .dashboard
    @State private var routePolicyReconciled = false

    private let routePolicyLog = Logger(
        subsystem: "com.ghoststream.vpn",
        category: "RoutePolicyLaunch"
    )

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                DashboardView()
                    .id(languageIdentity)
            }
            .tabItem {
                Label(AppTab.dashboard.label, systemImage: AppTab.dashboard.systemImageName)
            }
            .tag(AppTab.dashboard)

            NavigationStack {
                LogsView()
                    .id(languageIdentity)
            }
            .tabItem {
                Label(AppTab.logs.label, systemImage: AppTab.logs.systemImageName)
            }
            .tag(AppTab.logs)

            NavigationStack {
                SettingsView()
                    .id(languageIdentity)
            }
            .tabItem {
                Label(AppTab.settings.label, systemImage: AppTab.settings.systemImageName)
            }
            .tag(AppTab.settings)
        }
        .tint(C.signal)
        .toolbarBackground(C.bg, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task {
            await reconcileRoutePolicyOnLaunch()
        }
    }

    private var languageIdentity: String {
        prefs.languageOverride ?? "system"
    }

    @MainActor
    private func reconcileRoutePolicyOnLaunch() async {
        guard !routePolicyReconciled else { return }
        routePolicyReconciled = true

        guard let profile = profiles.activeProfile else { return }
        let routingMode = prefs.effectiveRoutingMode(
            profileSplitRouting: profile.splitRouting
        )
        guard routingMode != .global else { return }

        do {
            try await VpnTunnelController().applyRoutePolicy(
                profile: profile,
                preferences: prefs
            )
        } catch {
            routePolicyLog.warning(
                "launch route policy reconcile failed: \(error.localizedDescription, privacy: .public)"
            )
        }
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
