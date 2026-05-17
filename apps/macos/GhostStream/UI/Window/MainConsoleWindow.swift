//
//  MainConsoleWindow.swift
//  GhostStream (macOS)
//
//  NavigationSplitView host. Sidebar выбирает channel, detail pane
//  свитчится по выбранному ID. Command Palette — overlay.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct MainConsoleWindow: View {

    @Environment(\.gsColors) private var C
    @Environment(AppRouter.self) private var router

    public init() {}

    public var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarList()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            } detail: {
                detailPane
                    .navigationSplitViewColumnWidth(min: 740, ideal: 980)
            }
            .background(C.bg)
            // UI-R2-R02: when the command palette is open, the
            // underlying split view stays in the responder tree and
            // its `.keyboardShortcut` modifiers (CONNECT ⌘K, TailView
            // ⌘⌫, channel switch ⌘1..⌘4) still fire. Disable
            // interaction so the palette is the only thing taking
            // input. We deliberately do not move the palette to a
            // separate Window here — that would require a larger
            // refactor of focus / lifecycle wiring.
            .disabled(router.commandPaletteOpen)

            if router.commandPaletteOpen {
                CommandPalette()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch router.selectedChannel {
        case .stream:  DashboardView()
        case .tail:    TailView()
        case .setup:   SettingsView()
        case .roster:  ServerRosterView()
        }
    }
}
