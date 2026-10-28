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

/// Пункты сайдбара в порядке макета: Главная / Серверы / Логи / Админ /
/// Настройки. ⌘1…⌘5 — по этому же порядку.
public enum SidebarChannel: String, CaseIterable, Hashable, Identifiable {
    case stream
    case roster
    case tail
    case admin
    case setup

    public var id: String { rawValue }

    /// String-ключ (не `LocalizationValue`) — резолвится через `L(_:)`
    /// для живого переключения языка (LocalizationManager).
    public var localizedKey: String {
        switch self {
        case .stream: return "sidebar.stream"
        case .tail:   return "sidebar.tail"
        case .setup:  return "sidebar.setup"
        case .roster: return "sidebar.roster"
        case .admin:  return "sidebar.admin"
        }
    }

    public var sfSymbol: String {
        switch self {
        case .stream: return "house"
        case .roster: return "globe"
        case .tail:   return "list.bullet"
        case .admin:  return "person.2"
        case .setup:  return "gearshape"
        }
    }

    public var hotkey: Character {
        switch self {
        case .stream: return "1"
        case .roster: return "2"
        case .tail:   return "3"
        case .admin:  return "4"
        case .setup:  return "5"
        }
    }

    /// Channels to render for the current session. The ADMIN tab is
    /// identity-gated: it only exists when the active profile's client
    /// certificate is flagged `is_admin` on the server (cached via
    /// `/api/me` after a successful connect).
    public static func visible(adminUnlocked: Bool) -> [SidebarChannel] {
        allCases.filter { $0 != .admin || adminUnlocked }
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
