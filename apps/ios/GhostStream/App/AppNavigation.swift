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

    /// Short label shown under the glyph (mirrors Android).
    var label: String {
        switch self {
        case .dashboard: return NSLocalizedString("nav_stream", value: "Stream", comment: "")
        case .logs:      return NSLocalizedString("nav_logs", value: "Logs", comment: "")
        case .settings:  return NSLocalizedString("nav_settings", value: "Settings", comment: "")
        }
    }

    /// Android parity text glyph. Avoids SF Symbols while preserving the
    /// custom floating capsule visual.
    var glyph: String {
        switch self {
        case .dashboard: return "◉"
        case .logs:      return "▤"
        case .settings:  return "⚙"
        }
    }

    var accessibilityLabel: String {
        label
    }

    var previous: AppTab {
        let all = AppTab.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[max(index - 1, 0)]
    }

    var next: AppTab {
        let all = AppTab.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[min(index + 1, all.count - 1)]
    }
}

/// Root of the app UI. Custom bottom-nav pill over a `ZStack` of tab
/// content — avoids the default iOS `TabView` chrome and matches the
/// Android floating-capsule visual.
struct AppNavigation: View {

    @Environment(\.gsColors) private var C
    @State private var selection: AppTab = .dashboard
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            C.bg.ignoresSafeArea()

            // Tab content — keep all three mounted so state (view models,
            // timers) survives tab switches.
            ZStack {
                tabContent(.dashboard)
                    .opacity(selection == .dashboard ? 1 : 0)
                    .offset(x: selection == .dashboard ? dragOffset * 0.18 : 0)
                    .allowsHitTesting(selection == .dashboard)
                    .accessibilityHidden(selection != .dashboard)
                tabContent(.logs)
                    .opacity(selection == .logs ? 1 : 0)
                    .offset(x: selection == .logs ? dragOffset * 0.18 : 0)
                    .allowsHitTesting(selection == .logs)
                    .accessibilityHidden(selection != .logs)
                tabContent(.settings)
                    .opacity(selection == .settings ? 1 : 0)
                    .offset(x: selection == .settings ? dragOffset * 0.18 : 0)
                    .allowsHitTesting(selection == .settings)
                    .accessibilityHidden(selection != .settings)
            }
            .contentShape(Rectangle())
            .gesture(tabSwipeGesture)

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

    private var tabSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .updating($dragOffset) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height),
                      abs(value.translation.width) > 56
                else { return }

                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    selection = value.translation.width < 0 ? selection.next : selection.previous
                }
            }
    }
}

// MARK: - GhostBottomNav

/// Floating pill-shaped bottom navigation. Text glyphs mirror Android while
/// keeping the custom iOS capsule shell.
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
                Text(tab.glyph)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .scaleEffect(active ? 1.05 : 1.0)
                    .foregroundStyle(active ? C.signal : C.textDim)
                Text(tab.label)
                    .gsFont(.navItem)
                    .foregroundStyle(active ? C.bone : C.textFaint)
                    .opacity(active ? 1.0 : 0.55)
            }
            .frame(minWidth: 72)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? C.signal.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
