import SwiftUI

extension Color {
    static let darkBackground = Color(hex: 0x0F1118)
    static let darkSurface = Color(hex: 0x1A1D27)
    static let darkSurfaceVariant = Color(hex: 0x252836)

    static let lightBackground = Color(hex: 0xF5F5FA)
    static let lightSurface = Color(hex: 0xFFFFFF)
    static let lightSurfaceVariant = Color(hex: 0xEDE7F6)

    static let accentPurple = Color(hex: 0x7C4DFF)
    static let accentPurpleLight = Color(hex: 0xB388FF)
    static let accentIndigo = Color(hex: 0x536DFE)

    static let greenConnected = Color(hex: 0x69F0AE)
    static let redError = Color(hex: 0xFF5252)
    static let yellowWarning = Color(hex: 0xFFD740)
    static let blueDebug = Color(hex: 0x40C4FF)

    static let textPrimaryDark = Color(hex: 0xE0E0E0)
    static let textSecondaryDark = Color(hex: 0x9E9E9E)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
