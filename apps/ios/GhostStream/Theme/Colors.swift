//
//  Colors.swift
//  GhostStream
//
//  Port of android/app/src/main/kotlin/com/ghoststream/vpn/ui/theme/Color.kt
//  Two palettes: warm-black + phosphor-lime (dark) / paper + ink + moss (light).
//

import SwiftUI

// MARK: - Color(hex:) init

extension Color {
    /// Parses `0xRRGGBB` or `0xAARRGGBB` (Android-style ARGB) hex literals.
    /// Accepts UInt32 so call sites match the Kotlin source 1:1:
    ///     Color(hex: 0xFF0A0908)   // opaque warm-black (alpha=0xFF)
    ///     Color(hex: 0x0A0908)     // same, alpha defaults to 0xFF
    init(hex: UInt32) {
        let hasAlpha = hex > 0x00FFFFFF
        let a: Double = hasAlpha ? Double((hex >> 24) & 0xFF) / 255.0 : 1.0
        let r: Double = Double((hex >> 16) & 0xFF) / 255.0
        let g: Double = Double((hex >>  8) & 0xFF) / 255.0
        let b: Double = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - GsColorSet

/// Theme-aware colour bundle. Mirrors Kotlin `GsColorSet` field-for-field.
struct GsColorSet {
    let bg:        Color
    let bgElev:    Color
    let bgElev2:   Color
    let hair:      Color
    let hairBold:  Color
    let bone:      Color
    let textDim:   Color
    let textFaint: Color
    let signal:    Color
    let signalDim: Color
    let warn:      Color
    let danger:    Color

    // Back-compat aliases used across existing screens / dialogs (parity with Color.kt).
    var greenConnected: Color { signal }
    var redError:       Color { danger }
    var yellowWarning:  Color { warn }
    /// DEBUG log rows — constant across themes (same as Android `BlueDebug`).
    var blueDebug:      Color { Color(hex: 0xFF6C8BA8) }
    var textPrimary:    Color { bone }
    var textSecondary:  Color { textDim }
}

extension GsColorSet {
    // ── Dark "Ghoststream" palette (warm-black + phosphor-lime) ──────────────
    static let dark = GsColorSet(
        bg:        Color(hex: 0xFF0A0908),
        bgElev:    Color(hex: 0xFF12110E),
        bgElev2:   Color(hex: 0xFF17150F),
        hair:      Color(hex: 0xFF2A2619),
        hairBold:  Color(hex: 0xFF3D3828),
        bone:      Color(hex: 0xFFE8E2D0),
        textDim:   Color(hex: 0xFF948A6F),
        textFaint: Color(hex: 0xFF5A5240),
        signal:    Color(hex: 0xFFC4FF3E),
        signalDim: Color(hex: 0xFF4A6010),
        warn:      Color(hex: 0xFFFF7A3D),
        danger:    Color(hex: 0xFFFF4A3D)
    )

    // ── Light "Daylight" palette (paper + ink + moss-green) ──────────────────
    static let light = GsColorSet(
        bg:        Color(hex: 0xFFF1ECDC),
        bgElev:    Color(hex: 0xFFE8E2D0),
        bgElev2:   Color(hex: 0xFFDDD6C2),
        hair:      Color(hex: 0xFFCBC3AD),
        hairBold:  Color(hex: 0xFFB5AD96),
        bone:      Color(hex: 0xFF16130C), // ink
        textDim:   Color(hex: 0xFF5A5240),
        textFaint: Color(hex: 0xFF948A6F),
        signal:    Color(hex: 0xFF4A6010),
        signalDim: Color(hex: 0xFF7A9B30),
        warn:      Color(hex: 0xFFD4600A),
        danger:    Color(hex: 0xFFCC3322)
    )
}

// MARK: - Environment plumbing

private struct GsColorsKey: EnvironmentKey {
    static let defaultValue: GsColorSet = .dark
}

extension EnvironmentValues {
    /// Current Ghoststream colour palette. Read via `@Environment(\.gsColors) var C`.
    var gsColors: GsColorSet {
        get { self[GsColorsKey.self] }
        set { self[GsColorsKey.self] = newValue }
    }
}

/// Shorthand so call sites can mirror Kotlin `C.bg`, `C.signal`, etc.:
///     @Environment(\.gsColors) private var C
///     Text("...").foregroundColor(C.signal)
typealias C = GsColorSet
