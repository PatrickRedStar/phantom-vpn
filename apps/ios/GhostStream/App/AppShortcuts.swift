// App Shortcuts: Connect / Disconnect in Shortcuts, Siri and Spotlight
// without any setup. Phrases are English keys; translations live in
// Resources/<lang>.lproj/AppShortcuts.strings.

import AppIntents

struct GhostStreamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Turn on \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("shortcut.connect", table: "Widgets"),
            systemImageName: "checkmark.shield"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Turn off \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("shortcut.disconnect", table: "Widgets"),
            systemImageName: "shield.slash"
        )
    }
}
