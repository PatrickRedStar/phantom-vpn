// GhostStreamWidgets — home-screen widget, Control Center toggle (iOS 18+)
// and the VPN Live Activity. No PhantomKit here (it drags the Rust core into
// a ~30 MB extension): state is read straight from the App Group the app and
// the tunnel extension already write.

import SwiftUI
import WidgetKit

@main
struct GhostStreamWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
    }
}

// MARK: - Brand style (PhantomUI Theme, dark palette)

enum GS {
    static let bg = Color(hex: 0x0A0908)
    static let bone = Color(hex: 0xE8E2D0)
    static let dim = Color(hex: 0x948A6F)
    static let label = Color(hex: 0xB3A988)
    static let signal = Color(hex: 0xC4FF3E)
    static let warn = Color(hex: 0xFF7A3D)
    static let danger = Color(hex: 0xFF4A3D)

    // Bundled in this extension (UIAppFonts); a missing font falls back to the system one.
    static func grotesk(_ size: CGFloat) -> Font { .custom("SpaceGrotesk-Bold", fixedSize: size) }
    static func mono(_ size: CGFloat) -> Font { .custom("DepartureMono-Regular", fixedSize: size) }
    static func jet(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Regular", fixedSize: size) }

    /// "Передача" / "Transmitting"… A String (not an interpolated literal):
    /// interpolation would turn the key into "state.%@".
    static func stateWord(_ kind: SurfaceState.Kind) -> Text {
        Text(LocalizedStringKey("state." + kind.rawValue), tableName: "Widgets")
    }

    static func headlineColor(_ kind: SurfaceState.Kind) -> Color {
        switch kind {
        case .connected: return signal
        case .reconnecting: return warn
        case .error: return danger
        default: return bone
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
