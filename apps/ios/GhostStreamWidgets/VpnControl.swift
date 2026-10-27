// Control Center / Lock Screen / Action button toggle (iOS 18+).
// The value comes from the App Group; ToggleVPNIntent runs in the app.

import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct VpnControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.ghoststream.client.vpn", provider: Provider()) { value in
            ControlWidgetToggle("GhostStream", isOn: value.isOn, action: ToggleVPNIntent()) { isOn in
                Label {
                    if let name = value.profileName {
                        Text(name)
                    } else {
                        Text("control.no.profile", tableName: "Widgets")
                    }
                } icon: {
                    Image(systemName: isOn ? "checkmark.shield.fill" : "shield")
                }
            }
            .tint(GS.signal)
        }
        .displayName(LocalizedStringResource("control.name", table: "Widgets"))
        .description(LocalizedStringResource("control.description", table: "Widgets"))
    }

    struct Value {
        var isOn: Bool
        var profileName: String?
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value { Value(isOn: false, profileName: nil) }

        func currentValue() async throws -> Value {
            let state = SurfaceState.load()
            return Value(isOn: state.isOn, profileName: state.profileName)
        }
    }
}
