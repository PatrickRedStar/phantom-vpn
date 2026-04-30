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
