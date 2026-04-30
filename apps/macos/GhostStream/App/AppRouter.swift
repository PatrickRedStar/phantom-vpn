//
//  AppRouter.swift
//  GhostStream (macOS)
//
//  Coordinator for window state, sidebar selection, command-palette
//  visibility, and global hotkey routing. Owned by `GhostStreamApp` and
//  injected as an environment object.
//

import AppKit
import Foundation
import Observation

/// Identifies the four (eventually five) main console tabs.
public enum SidebarChannel: String, CaseIterable, Hashable, Identifiable {
    case stream
    case tail
    case setup
    case roster

    public var id: String { rawValue }

    public var localizedKey: String.LocalizationValue {
        switch self {
        case .stream: return "sidebar.stream"
        case .tail:   return "sidebar.tail"
        case .setup:  return "sidebar.setup"
        case .roster: return "sidebar.roster"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .stream: return "dot.radiowaves.left.and.right"
        case .tail:   return "list.bullet.rectangle"
        case .setup:  return "slider.horizontal.3"
        case .roster: return "server.rack"
        }
    }

    public var hotkey: Character {
        switch self {
        case .stream: return "1"
        case .tail:   return "2"
        case .setup:  return "3"
        case .roster: return "4"
        }
    }
}

@MainActor
@Observable
public final class AppRouter {

    public static let shared = AppRouter()

    public var selectedChannel: SidebarChannel = .stream
    public var commandPaletteOpen: Bool = false
    public var detachedLogsOpen: Bool = false

    private init() {}

    public func select(_ channel: SidebarChannel) {
        selectedChannel = channel
    }

    public func toggleCommandPalette() {
        commandPaletteOpen.toggle()
    }

    public func openDetachedLogs() {
        detachedLogsOpen = true
    }
}
