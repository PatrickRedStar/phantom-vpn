//
//  CommandPalette.swift
//  GhostStream (macOS)
//
//  Палитра команд (⇧⌘C): профили, действия, переход по разделам. Всё
//  по-русски через L(), поиск — по тем же русским названиям.
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
    @Environment(DockPolicyController.self) private var dock
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
                RoundedRectangle(cornerRadius: GsRadius.window, style: .continuous).fill(
                    LinearGradient(
                        colors: [C.bg.opacity(0.95), C.bg.opacity(0.98)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .gsClip(GsRadius.window)
            .overlay(RoundedRectangle(cornerRadius: GsRadius.window, style: .continuous).stroke(C.hairBold, lineWidth: 1))
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
        // UI-C4: Enter is handled exclusively by the TextField's
        // `.onSubmit`. The previous view-level `.onKeyPress(.return)`
        // ran in parallel and produced two `runSelected()` calls per
        // press — manifesting as duplicate `installAndStart` tasks.
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
            TextField(L("command_palette.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .foregroundStyle(C.bone)
                .focused($fieldFocused)
                .onSubmit {
                    statusMessage = nil
                    runSelected()
                }
            KeyboardShortcutHint("esc")
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
                .gsType(.caption)
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
            // ~15 строк — ленивый стек не нужен (и в нём строки мигали пустыми).
            VStack(spacing: 0) {
                let groups = filteredGroups
                // UI-H7: precompute the running flat-index offsets so
                // each row knows its position in the linearised list
                // without mutating a `var` from inside a ViewBuilder
                // (that produced stale selection highlighting on
                // rapid typing because SwiftUI re-evaluates body in
                // unspecified order).
                let groupOffsets: [Int] = {
                    var offsets: [Int] = []
                    var running = 0
                    for group in groups {
                        offsets.append(running)
                        running += group.items.count
                    }
                    return offsets
                }()
                if groups.isEmpty {
                    Text(L("palette.no_matches"))
                        .gsType(.body)
                        .foregroundStyle(C.textFaint)
                        .padding(.vertical, 30)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { groupIndex, group in
                        sectionLabel(group.section)
                        ForEach(Array(group.items.enumerated()), id: \.offset) { itemIndex, item in
                            let flatIndex = groupOffsets[groupIndex] + itemIndex
                            rowView(item, active: flatIndex == selection)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionLabel(_ name: String) -> some View {
        HStack {
            Text(name)
                .gsType(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(C.textDim)
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
                        .gsType(.body)
                        .foregroundStyle(active ? C.signal : C.bone)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .gsType(.caption)
                            .foregroundStyle(C.textDim)
                    }
                }
                .lineLimit(1)

                Spacer()

                if let kbd = item.kbd {
                    KeyboardShortcutHint(kbd)
                } else if active {
                    KeyboardShortcutHint("↵")
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous)
                    .fill(active ? C.signal.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerHint: some View {
        HStack(spacing: 18) {
            footerItem(kbd: "↑↓", text: L("palette.navigate"))
            footerItem(kbd: "↵",  text: L("palette.run"))
            Spacer()
            Text(selectedCounter)
                .gsType(.caption)
                .monospacedDigit()
                .foregroundStyle(C.textDim)
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
                .gsType(.caption)
                .foregroundStyle(C.textDim)
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
        let state = stateMgr.statusFrame.state

        // 1. Профили. RTT — только у активного: он один и замерен.
        let profilesSection = L("palette.section.profiles")
        let profileItems: [PaletteItem] = profiles.profiles.map { profile in
            let isActive = profile.id == profiles.activeProfile?.id
            let rtt = isActive && state == .connected
                ? stateMgr.statusFrame.rttMs.map { " · \($0) " + L("palette.ms") } ?? ""
                : ""
            return PaletteItem(
                id: "profile.\(profile.id)",
                title: String(format: L("palette.connect_to"), profile.name),
                subtitle: profile.effectiveServerAddr + rtt,
                section: profilesSection,
                icon: isActive ? "checkmark.circle" : "dot.radiowaves.left.and.right",
                kbd: nil,
                action: {
                    profiles.setActive(id: profile.id)
                    // Туннель поднят: на новый профиль переподключит
                    // VpnTunnelController.activeProfileChanged (наблюдатель
                    // activeProfile в GhostStreamApp) — второй старт не нужен.
                    if VpnTunnelController.isUp(stateMgr.statusFrame.state) {
                        return .close
                    }
                    return start(profile)
                }
            )
        }
        if !profileItems.isEmpty {
            groups.append(Group(section: profilesSection, items: profileItems))
        }

        // 2. Действия
        let actionsSection = L("palette.section.actions")
        let isUp = VpnTunnelController.isUp(state)
        var actionItems: [PaletteItem] = []
        actionItems.append(.init(
            id: "act.disconnect",
            title: L(isUp ? "action.disconnect" : "action.connect"),
            subtitle: isUp ? L("palette.disconnect.sub") : profiles.activeProfile?.name,
            section: actionsSection,
            icon: "power",
            kbd: nil,
            action: {
                if isUp {
                    tunnel.stop()
                    return .close
                } else if let p = profiles.activeProfile {
                    return start(p)
                } else {
                    return openSetupWithError(L("palette.no_profile"))
                }
            }
        ))
        actionItems.append(.init(
            id: "act.reconnect",
            title: L("settings.reconnect"),
            subtitle: L("palette.reconnect.sub"),
            section: actionsSection,
            icon: "arrow.clockwise",
            kbd: nil,
            action: {
                return reconnectActive()
            }
        ))
        actionItems.append(.init(
            id: "act.theme",
            title: L("palette.theme"),
            subtitle: L("palette.theme.sub"),
            section: actionsSection,
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
            title: L("update.check_menu"),
            subtitle: "GitHub",
            section: actionsSection,
            icon: "arrow.down.circle",
            kbd: nil,
            action: {
                let updates = UpdateChecker.shared
                if let release = updates.available {
                    NSWorkspace.shared.open(release.url)
                    return .close
                }
                Task {
                    await updates.check()
                    statusMessage = .init(
                        text: updates.available.map { String(format: L("update.available"), $0.version) }
                            ?? (updates.lastCheck == nil ? L("update.check_failed") : L("update.latest")),
                        kind: .info
                    )
                }
                return .stayOpen
            }
        ))
        actionItems.append(.init(
            id: "act.logs",
            title: L("palette.logs"),
            subtitle: nil,
            section: actionsSection,
            icon: "macwindow.on.rectangle",
            kbd: "⇧⌘L",
            action: {
                router.openDetachedLogs()
                openForegroundWindow("logs")
                return .close
            }
        ))
        actionItems.append(.init(
            id: "act.about",
            title: L("menu.about"),
            subtitle: nil,
            section: actionsSection,
            icon: "info.circle",
            kbd: nil,
            action: {
                openForegroundWindow("about")
                return .close
            }
        ))
        actionItems.append(.init(
            id: "act.quit",
            title: L("palette.quit"),
            subtitle: nil,
            section: actionsSection,
            icon: "xmark.circle",
            kbd: "⌘Q",
            action: {
                NSApp.terminate(nil)
                return .close
            }
        ))
        groups.append(Group(section: actionsSection, items: actionItems))

        // 3. Переход по разделам — «Админ» только для админ-профиля, как в сайдбаре.
        let navSection = L("palette.section.nav")
        let adminUnlocked = profiles.activeProfile?.cachedIsAdmin == true
        let navItems: [PaletteItem] = SidebarChannel.visible(adminUnlocked: adminUnlocked).map { channel in
            PaletteItem(
                id: "nav.\(channel.rawValue)",
                title: String(format: L("palette.go_to"), L(channel.localizedKey)),
                subtitle: nil,
                section: navSection,
                icon: channel.sfSymbol,
                kbd: "⌘\(channel.hotkey)",
                action: {
                    router.select(channel)
                    return .close
                }
            )
        }
        groups.append(Group(section: navSection, items: navItems))

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

        statusMessage = .init(text: String(format: L("palette.connecting"), profile.name), kind: .info)
        Task {
            do {
                try await tunnel.installAndStart(
                    profile: profile,
                    preferences: PreferencesStore.shared
                )
                tunnel.lastError = nil
                router.commandPaletteOpen = false
            } catch {
                let humanized = ConnectErrorHumanizer.humanize(error.localizedDescription)
                tunnel.lastError = humanized
                statusMessage = .init(text: humanized, kind: .error)
            }
        }
        return .stayOpen
    }

    private func reconnectActive() -> PaletteActionResult {
        guard let profile = profiles.activeProfile else {
            return openSetupWithError(L("palette.no_profile"))
        }

        if let preflightError = connectPreflightError() {
            return openSetupWithError(preflightError)
        }

        statusMessage = .init(text: String(format: L("palette.reconnecting"), profile.name), kind: .info)
        Task {
            // stop → дождаться .disconnected → start (ошибку старта
            // installAndStart кладёт в tunnel.lastError).
            await tunnel.restart(with: profile, preferences: PreferencesStore.shared).value
            if let error = tunnel.lastError {
                statusMessage = .init(text: error, kind: .error)
            } else {
                router.commandPaletteOpen = false
            }
        }
        return .stayOpen
    }

    private func connectPreflightError() -> String? {
        switch sysExt.state {
        case .activated:
            return nil
        case .failed(let message):
            return message
        case .awaitingUserApproval, .requestPending, .notInstalled:
            return L("palette.sysext_not_ready")
        }
    }

    private func openSetupWithError(_ message: String) -> PaletteActionResult {
        // UI-H13 partial: surface the error in the palette's own
        // status banner AND on `tunnel.lastError` because the Welcome
        // window reads the latter. A full single-source-of-truth
        // refactor needs the Service layer (out of UI scope here),
        // so this is the minimum-invasive seam: the palette
        // dismisses immediately after `openSetupWithError`, so the
        // user never sees both banners at once.
        tunnel.lastError = message
        statusMessage = .init(text: message, kind: .error)
        openForegroundWindow("welcome")
        return .close
    }

    private func openForegroundWindow(_ id: String) {
        openWindow(id: id)
        dock.activateForegroundWindow()
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
