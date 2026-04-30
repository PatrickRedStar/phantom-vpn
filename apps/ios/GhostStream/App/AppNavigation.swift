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

/// Tab identifier for the bottom nav.
enum AppTab: Int, CaseIterable, Hashable {
    case dashboard
    case logs
    case settings

    /// Short ALL-CAPS label shown under the glyph (mirrors Android).
    var label: String {
        switch self {
        case .dashboard: return "STREAM"
        case .logs:      return "TAIL"
        case .settings:  return "SETUP"
        }
    }

    /// SF Symbol name for the glyph.
    var systemImage: String {
        switch self {
        case .dashboard: return "dot.radiowaves.left.and.right"
        case .logs:      return "list.bullet.rectangle"
        case .settings:  return "slider.horizontal.3"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .dashboard: return "Stream"
        case .logs:      return "Tail"
        case .settings:  return "Setup"
        }
    }
}

/// Root of the app UI. Custom bottom-nav pill over a `ZStack` of tab
/// content — avoids the default iOS `TabView` chrome and matches the
/// Android floating-capsule visual.
struct AppNavigation: View {

    @Environment(\.gsColors) private var C
    @State private var selection: AppTab = .dashboard

    var body: some View {
        ZStack(alignment: .bottom) {
            C.bg.ignoresSafeArea()

            // Tab content — keep all three mounted so state (view models,
            // timers) survives tab switches.
            ZStack {
                tabContent(.dashboard)
                    .opacity(selection == .dashboard ? 1 : 0)
                    .allowsHitTesting(selection == .dashboard)
                    .accessibilityHidden(selection != .dashboard)
                tabContent(.logs)
                    .opacity(selection == .logs ? 1 : 0)
                    .allowsHitTesting(selection == .logs)
                    .accessibilityHidden(selection != .logs)
                tabContent(.settings)
                    .opacity(selection == .settings ? 1 : 0)
                    .allowsHitTesting(selection == .settings)
                    .accessibilityHidden(selection != .settings)
            }

            // Gradient fade behind the nav so scrolling content doesn't
            // collide with the floating pill.
            LinearGradient(
                colors: [C.bg.opacity(0), C.bg.opacity(0.95), C.bg],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 80)
            .allowsHitTesting(false)
            .frame(maxWidth: .infinity, alignment: .bottom)

            GhostBottomNav(selection: $selection)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: AppTab) -> some View {
        NavigationStack {
            switch tab {
            case .dashboard:
                DashboardView()
            case .logs:
                LogsView()
            case .settings:
                // SettingsView owns its own file (separate agent turf).
                // Reference it by name; if not yet present, builds will
                // surface a clear error in the Settings agent's scope.
                SettingsView()
            }
        }
    }
}

// MARK: - GhostBottomNav

/// Floating pill-shaped bottom navigation. Animated sliding indicator,
/// glyph scale on active tab, label fade on inactive.
private struct GhostBottomNav: View {

    @Binding var selection: AppTab
    @Environment(\.gsColors) private var C

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                navButton(for: tab)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(C.bgElev.opacity(0.95))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(C.hair, lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    @ViewBuilder
    private func navButton(for tab: AppTab) -> some View {
        let active = tab == selection
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                selection = tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .scaleEffect(active ? 1.05 : 1.0)
                    .foregroundStyle(active ? C.signal : C.textDim)
                Text(tab.label)
                    .gsFont(.navItem)
                    .foregroundStyle(active ? C.signal : C.textDim)
                    .opacity(active ? 1.0 : 0.55)
            }
            .frame(minWidth: 72)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(active ? C.signal.opacity(0.10) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(active ? .isSelected : [])
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
