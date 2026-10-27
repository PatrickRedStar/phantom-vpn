// VPN intents for Shortcuts / Siri, the home-screen widget, the Control
// Center toggle and the Live Activity button.
//
// Compiled into both the app and the GhostStreamWidgets extension: the widget
// needs the types for Button(intent:) / ControlWidgetToggle. They conform to
// LiveActivityIntent, so the system runs perform() in the app process
// (launching it in the background if needed) — only the app has the
// profiles, the Keychain secrets and the NETunnelProviderManager config.
// The widget-extension copy of perform() is never called.

import AppIntents

struct ConnectVPNIntent: LiveActivityIntent {
    static let title = LocalizedStringResource("intent.connect.title", table: "Widgets")
    static let description = IntentDescription(LocalizedStringResource("intent.connect.description", table: "Widgets"))

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        try await VpnActions.connect()
        #endif
        return .result()
    }
}

struct DisconnectVPNIntent: LiveActivityIntent {
    static let title = LocalizedStringResource("intent.disconnect.title", table: "Widgets")
    static let description = IntentDescription(LocalizedStringResource("intent.disconnect.description", table: "Widgets"))

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        await VpnActions.disconnect()
        #endif
        return .result()
    }
}

/// Control Center toggle action. Hidden from Shortcuts: Connect/Disconnect cover it.
struct ToggleVPNIntent: SetValueIntent, LiveActivityIntent {
    static let title = LocalizedStringResource("intent.toggle.title", table: "Widgets")
    static let isDiscoverable = false

    @Parameter(title: LocalizedStringResource("intent.toggle.value", table: "Widgets"))
    var value: Bool

    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        if value {
            try await VpnActions.connect()
        } else {
            await VpnActions.disconnect()
        }
        #endif
        return .result()
    }
}
