//
//  CommandPalette.swift
//  GhostStream (macOS)
//
//  Pixel-matched to section 07 of the design HTML.
//
//   • Floating 600×420 panel, hairBold 1pt border, semi-transparent bg.
//   • Header row 18×22pt: signal magnifier glyph + mono 18pt input
//     + esc-pill on the right.
//   • Section dividers (mono 9.5pt 0.18em faint) between groups.
//   • Rows 14×10pt with [icon 16pt][title body 13.5pt][meta tag mono
//     10pt faint][kbd hint]. Active row: signal text + signal.opacity(0.06)
//     bg.
//   • Footer 22×10pt mono 9.5pt: ↑↓ navigate · ↵ execute · selected/total.
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct CommandPalette: View {

    @Environment(\.gsColors) private var C
    @Environment(AppRouter.self) private var router
    @Environment(ProfilesStore.self) private var profiles
    @EnvironmentObject private var tunnel: VpnTunnelController
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(SystemExtensionInstaller.self) private var sysExt
    @Environment(\.openWindow) private var openWindow

    @State private var query: String = ""
    @State private var selection: Int = 0
    @State private var statusMessage: PaletteStatusMessage?
    @FocusState private var fieldFocused: Bool

    public init() {}

    public var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { router.commandPaletteOpen = false }

            VStack(alignment: .leading, spacing: 0) {
                inputRow
                Rectangle().fill(C.hair).frame(height: 1)
                if let statusMessage {
                    statusBanner(statusMessage)
                    Rectangle().fill(C.hair).frame(height: 1)
                }
                resultList
                Rectangle().fill(C.hair).frame(height: 1)
                footerHint
            }
            .frame(width: 600, height: 420)
            .background(
                LinearGradient(
                    colors: [C.bg.opacity(0.95), C.bg.opacity(0.98)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 32, y: 12)
            .padding(.top, 60)
        }
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in clampSelection() }
        .onChange(of: filteredItemCount) { _, _ in clampSelection() }
        .onExitCommand { router.commandPaletteOpen = false }
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.return) {
            runSelected()
            return .handled
        }
        .onKeyPress(.escape) {
            router.commandPaletteOpen = false
            return .handled
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var inputRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(C.signal)
                .frame(width: 18, height: 18)
                .font(.system(size: 16, weight: .regular))
            TextField(String(localized: "command_palette.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.custom("JetBrainsMono-Regular", size: 18))
                .foregroundStyle(C.bone)
                .focused($fieldFocused)
                .onSubmit {
                    statusMessage = nil
                    runSelected()
                }
            Text("ESC")
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.14 * 9.5)
                .foregroundStyle(C.textFaint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private func statusBanner(_ message: PaletteStatusMessage) -> some View {
        let isError: Bool = {
            if case .error = message.kind { return true }
            return false
        }()
        let color = isError ? C.danger : C.signal
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle" : "dot.radiowaves.left.and.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16, height: 16)
            Text(message.text)
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .foregroundStyle(isError ? C.bone : C.textDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(color.opacity(0.06))
    }

    // MARK: - Result list

    @ViewBuilder
    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                let groups = filteredGroups
                if groups.isEmpty {
                    Text("Нет совпадений")
                        .font(.custom("JetBrainsMono-Regular", size: 13))
                        .foregroundStyle(C.textFaint)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                } else {
                    var index = 0
                    ForEach(groups, id: \.section) { group in
                        sectionLabel(group.section)
                        ForEach(group.items) { item in
                            let activeIdx = index
                            rowView(item, active: activeIdx == selection)
                            // Track ordering — mutate before next item.
                            let _ = (index += 1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ name: String) -> some View {
        HStack {
            Text(name.lowercased())
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.18 * 9.5)
                .foregroundStyle(C.textFaint)
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func rowView(_ item: PaletteItem, active: Bool) -> some View {
        Button {
            run(item)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: item.icon)
                    .frame(width: 16, height: 16)
                    .foregroundStyle(active ? C.signal : C.textDim.opacity(0.85))
                    .font(.system(size: 13))

                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.custom("JetBrainsMono-Regular", size: 13.5))
                        .foregroundStyle(active ? C.signal : C.bone)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.custom("JetBrainsMono-Regular", size: 12))
                            .foregroundStyle(C.textFaint)
                    }
                }

                Spacer()

                Text(item.section.lowercased())
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.14 * 10)
                    .foregroundStyle(C.textFaint)

                if let kbd = item.kbd {
                    KeyboardShortcutHint(kbd)
                } else if active {
                    KeyboardShortcutHint("↵")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(active ? C.signal.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerHint: some View {
        HStack(spacing: 18) {
            footerItem(kbd: "↑↓", text: "navigate")
            footerItem(kbd: "↵",  text: "execute")
            Spacer()
            Text("\(selectedCounter) · \(profiles.profiles.count) profiles")
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.16 * 9.5)
                .foregroundStyle(C.textFaint)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(C.bg)
    }

    @ViewBuilder
    private func footerItem(kbd: String, text: String) -> some View {
        HStack(spacing: 6) {
            KeyboardShortcutHint(kbd)
            Text(text)
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.16 * 9.5)
                .foregroundStyle(C.textFaint)
        }
    }

    // MARK: - Items

    private struct PaletteItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let section: String
        let icon: String
        let kbd: String?
        let action: () -> PaletteActionResult
    }

    private struct Group {
        let section: String
        let items: [PaletteItem]
    }

    private enum PaletteActionResult {
        case close
        case stayOpen
    }

    private enum PaletteStatusKind {
        case info
        case error
    }

    private struct PaletteStatusMessage {
        let text: String
        let kind: PaletteStatusKind
    }

    private var allGroups: [Group] {
        var groups: [Group] = []

        // 1. Profile rows
        let profileItems: [PaletteItem] = profiles.profiles.map { profile in
            let rttSuffix = stateMgr.statusFrame.rttMs.map { " · \($0)ms" } ?? ""
            return PaletteItem(
                id: "profile.\(profile.id)",
                title: "Connect to \(profile.name)",
                subtitle: profile.serverAddr + rttSuffix,
                section: "PROFILES",
                icon: "dot.radiowaves.left.and.right",
                kbd: nil,
                action: {
                    profiles.setActive(id: profile.id)
                    return start(profile)
                }
            )
        }
        if !profileItems.isEmpty {
            groups.append(Group(section: "PROFILES", items: profileItems))
        }

        // 2. Actions
        let isLive = stateMgr.statusFrame.state == .connected
        var actionItems: [PaletteItem] = []
        actionItems.append(.init(
            id: "act.disconnect",
            title: isLive ? "Disconnect" : "Connect",
            subtitle: isLive ? "stop tunnel immediately" : "use the active profile",
            section: "ACTIONS",
            icon: isLive ? "power.circle.fill" : "power.circle",
            kbd: nil,
            action: {
                if isLive {
                    tunnel.stop()
                    return .close
                } else if let p = profiles.activeProfile {
                    return start(p)
                } else {
                    return openSetupWithError("No VPN profile selected. Opening setup to import one.")
                }
            }
        ))
        actionItems.append(.init(
            id: "act.reconnect",
            title: "Reconnect",
            subtitle: "restart tunnel",
            section: "ACTIONS",
            icon: "arrow.clockwise.circle",
            kbd: nil,
            action: {
                return reconnectActive()
            }
        ))
        actionItems.append(.init(
            id: "act.theme",
            title: "Toggle theme",
            subtitle: "system → dark → light",
            section: "ACTIONS",
            icon: "circle.lefthalf.filled",
            kbd: nil,
            action: {
                let p = PreferencesStore.shared
                switch ThemeOverride(rawValue: p.theme) ?? .system {
                case .system: p.theme = ThemeOverride.dark.rawValue
                case .dark: p.theme = ThemeOverride.light.rawValue
                case .light: p.theme = ThemeOverride.system.rawValue
                }
                return .close
            }
        ))
        actionItems.append(.init(
            id: "act.updates",
            title: "Check for updates",
            subtitle: "unavailable: Sparkle not integrated",
            section: "ACTIONS",
            icon: "arrow.down.circle",
            kbd: nil,
            action: {
                tunnel.lastError = "Check for updates is unavailable: Sparkle is not integrated"
                return .close
            }
        ))
        actionItems.append(.init(
            id: "act.logs",
            title: "Open detached logs",
            subtitle: "tail window",
            section: "ACTIONS",
            icon: "rectangle.on.rectangle",
            kbd: "⇧⌘L",
            action: {
                router.openDetachedLogs()
                openWindow(id: "logs")
                return .close
            }
        ))
        actionItems.append(.init(
            id: "act.about",
            title: "About GhostStream",
            subtitle: "version and credits",
            section: "ACTIONS",
            icon: "info.circle",
            kbd: nil,
            action: {
                openWindow(id: "about")
                return .close
            }
        ))
        actionItems.append(.init(
            id: "act.quit",
            title: "Quit GhostStream",
            subtitle: "close the app",
            section: "ACTIONS",
            icon: "xmark.circle",
            kbd: "⌘Q",
            action: {
                NSApp.terminate(nil)
                return .close
            }
        ))
        groups.append(Group(section: "ACTIONS", items: actionItems))

        // 3. Navigation jumps
        let navItems: [PaletteItem] = SidebarChannel.allCases.map { channel in
            PaletteItem(
                id: "nav.\(channel.rawValue)",
                title: "Go to \(String(localized: channel.localizedKey))",
                subtitle: nil,
                section: "NAV",
                icon: channel.sfSymbol,
                kbd: "⌘\(channel.hotkey)",
                action: {
                    router.select(channel)
                    return .close
                }
            )
        }
        groups.append(Group(section: "NAV", items: navItems))

        return groups
    }

    private var filteredGroups: [Group] {
        guard !query.isEmpty else { return allGroups }
        let q = query.lowercased()
        return allGroups.compactMap { group in
            let filtered = group.items
                .compactMap { item -> (PaletteItem, Int)? in
                    guard let score = fuzzyScore(query: q, item: item) else { return nil }
                    return (item, score)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
            return filtered.isEmpty ? nil : Group(section: group.section, items: filtered)
        }
    }

    private var filteredItems: [PaletteItem] {
        filteredGroups.flatMap(\.items)
    }

    private var filteredItemCount: Int {
        filteredGroups.reduce(0) { $0 + $1.items.count }
    }

    private var selectedCounter: String {
        guard filteredItemCount > 0 else { return "0 / 0" }
        return "\(selection + 1) / \(filteredItemCount)"
    }

    private func run(_ item: PaletteItem) {
        statusMessage = nil
        switch item.action() {
        case .close:
            router.commandPaletteOpen = false
        case .stayOpen:
            break
        }
    }

    private func runSelected() {
        let items = filteredItems
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    private func moveSelection(_ delta: Int) {
        let count = filteredItemCount
        guard count > 0 else {
            selection = 0
            return
        }
        selection = (selection + delta + count) % count
    }

    private func clampSelection() {
        let count = filteredItemCount
        selection = count == 0 ? 0 : min(selection, count - 1)
    }

    private func start(_ profile: VpnProfile) -> PaletteActionResult {
        if let preflightError = connectPreflightError() {
            return openSetupWithError(preflightError)
        }

        statusMessage = .init(text: "Connecting to \(profile.name)...", kind: .info)
        Task {
            do {
                try await tunnel.installAndStart(
                    profile: profile,
                    preferences: PreferencesStore.shared
                )
                tunnel.lastError = nil
                router.commandPaletteOpen = false
            } catch {
                tunnel.lastError = error.localizedDescription
                statusMessage = .init(text: error.localizedDescription, kind: .error)
            }
        }
        return .stayOpen
    }

    private func reconnectActive() -> PaletteActionResult {
        guard let profile = profiles.activeProfile else {
            return openSetupWithError("No VPN profile selected. Opening setup to import one.")
        }

        if let preflightError = connectPreflightError() {
            return openSetupWithError(preflightError)
        }

        tunnel.stop()
        statusMessage = .init(text: "Reconnecting to \(profile.name)...", kind: .info)
        Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                try await tunnel.installAndStart(profile: profile, preferences: PreferencesStore.shared)
                tunnel.lastError = nil
                router.commandPaletteOpen = false
            } catch {
                tunnel.lastError = error.localizedDescription
                statusMessage = .init(text: error.localizedDescription, kind: .error)
            }
        }
        return .stayOpen
    }

    private func connectPreflightError() -> String? {
        switch sysExt.state {
        case .activated:
            return nil
        case .failed(let message):
            return "System extension is not ready: \(message). Opening setup."
        case .awaitingUserApproval:
            return "System extension is waiting for approval. Opening setup."
        case .requestPending:
            return "System extension install is still pending. Opening setup."
        case .notInstalled:
            return "System extension is not installed yet. Opening setup."
        }
    }

    private func openSetupWithError(_ message: String) -> PaletteActionResult {
        tunnel.lastError = message
        statusMessage = .init(text: message, kind: .error)
        openWindow(id: "welcome")
        NSApp.activate(ignoringOtherApps: true)
        return .close
    }

    private func fuzzyScore(query: String, item: PaletteItem) -> Int? {
        let haystack = [
            item.title,
            item.subtitle ?? "",
            item.section,
            item.kbd ?? ""
        ].joined(separator: " ").lowercased()

        if haystack.contains(query) { return query.count }

        var score = 0
        var searchStart = haystack.startIndex
        var lastMatch: String.Index?

        for char in query {
            guard let found = haystack[searchStart...].firstIndex(of: char) else {
                return nil
            }
            score += haystack.distance(from: searchStart, to: found)
            if let lastMatch {
                score += haystack.distance(from: lastMatch, to: found) == 1 ? 0 : 3
            }
            lastMatch = found
            searchStart = haystack.index(after: found)
        }

        return score + haystack.count
    }
}
