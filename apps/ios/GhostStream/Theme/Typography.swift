//
//  Typography.swift
//  GhostStream
//
//  Port of android/app/src/main/kotlin/com/ghoststream/vpn/ui/theme/Typography.kt
//
//  Font families (files copied to Theme/Fonts/):
//    - InstrumentSerif        — instrument_serif.ttf / instrument_serif_italic.ttf
//    - SpaceGrotesk           — space_grotesk.ttf / space_grotesk_bold.ttf
//    - DepartureMono          — departure_mono.otf
//    - JetBrainsMono          — jetbrains_mono.ttf / jetbrains_mono_medium.ttf
//
//  NOTE: The PostScript names below are best-guess from the upstream font
//  distributions. Verify at runtime with:
//      for family in UIFont.familyNames.sorted() {
//          print(family, UIFont.fontNames(forFamilyName: family))
//      }
//  and correct any mismatches.
//

import SwiftUI

// MARK: - PostScript names (per font file)

enum GsFontName {
    // Instrument Serif — TODO: verify at runtime via UIFont.fontNames(forFamilyName:)
    static let instrumentSerif        = "InstrumentSerif-Regular"
    static let instrumentSerifItalic  = "InstrumentSerif-Italic"

    // Space Grotesk — TODO: verify at runtime via UIFont.fontNames(forFamilyName:)
    static let spaceGrotesk           = "SpaceGrotesk-Regular"
    static let spaceGroteskMedium     = "SpaceGrotesk-Medium"
    static let spaceGroteskBold       = "SpaceGrotesk-Bold"

    // Departure Mono — TODO: verify at runtime via UIFont.fontNames(forFamilyName:)
    static let departureMono          = "DepartureMono-Regular"

    // JetBrains Mono — TODO: verify at runtime via UIFont.fontNames(forFamilyName:)
    static let jetBrainsMono          = "JetBrainsMono-Regular"
    static let jetBrainsMonoMedium    = "JetBrainsMono-Medium"
}

// MARK: - GsFont — named text styles

/// Mirrors Kotlin `object GsText { ... }`.
/// Apply to a `Text` via the `.gsFont(_:)` modifier, which also wires
/// letter-spacing (em → points) and line-height.
enum GsFont {
    // ── Space Grotesk (brand / hero / titles) ────────────────────────────────
    case brand            // 22sp bold, -0.02em
    case specTitle        // 42sp bold, -0.02em
    case stateHeadline    // 54sp bold, lineHeight 56, -0.035em
    case profileName      // 18sp bold, -0.01em
    case clientName       // 17sp bold, -0.01em
    case statValue        // 24sp bold, lineHeight 24, -0.01em
    case hint             // 22sp regular, -0.01em

    // ── Departure Mono (ALL CAPS labels, tickers, numeric strips) ────────────
    case labelMono        // 10.5sp, 0.18em
    case labelMonoSmall   // 10sp,   0.15em
    case labelMonoTiny    // 9.5sp,  0.14em
    case hdrMeta          // 10.5sp, 0.12em
    case ticker           // 26sp,   0.04em
    case valueMono        // 11sp,   0.08em
    case chipText         // 10.5sp, 0.12em
    case navItem          // 10sp,   0.14em
    case fabText          // 11sp,   0.20em, medium

    // ── JetBrains Mono (body, logs, addresses) ───────────────────────────────
    case body             // 12sp
    case bodyMedium       // 11.5sp
    case kvValue          // 11sp
    case host             // 10sp
    case logTs            // 9sp
    case logLevel         // 9.5sp Departure, 0.12em
    case logMsg           // 10.5sp, lineHeight 16

    // ── Material baseline equivalents (GsTypography) ─────────────────────────
    case bodyLarge        // 14sp JetBrains
    case bodySmall        // 11sp JetBrains
    case titleLarge       // 22sp Space Grotesk bold
    case titleMedium      // 17sp Space Grotesk bold
    case titleSmall       // 11sp Departure, 0.15em
    case labelLarge       // 11sp Departure, 0.15em
    case labelMedium      // 10.5sp Departure, 0.14em
    case labelSmall       // 9.5sp Departure, 0.12em

    /// Resolved spec for this style.
    var spec: GsFontSpec {
        switch self {
        // Space Grotesk
        case .brand:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 22,   letterSpacingEm: -0.02)
        case .specTitle:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 42,   letterSpacingEm: -0.02)
        case .stateHeadline:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 54,   letterSpacingEm: -0.035, lineHeight: 56)
        case .profileName:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 18,   letterSpacingEm: -0.01)
        case .clientName:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 17,   letterSpacingEm: -0.01)
        case .statValue:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 24,   letterSpacingEm: -0.01,  lineHeight: 24)
        case .hint:
            return GsFontSpec(name: GsFontName.spaceGrotesk,         size: 22,   letterSpacingEm: -0.01)

        // Departure Mono
        case .labelMono:
            return GsFontSpec(name: GsFontName.departureMono,        size: 10.5, letterSpacingEm: 0.18)
        case .labelMonoSmall:
            return GsFontSpec(name: GsFontName.departureMono,        size: 10,   letterSpacingEm: 0.15)
        case .labelMonoTiny:
            return GsFontSpec(name: GsFontName.departureMono,        size: 9.5,  letterSpacingEm: 0.14)
        case .hdrMeta:
            return GsFontSpec(name: GsFontName.departureMono,        size: 10.5, letterSpacingEm: 0.12)
        case .ticker:
            return GsFontSpec(name: GsFontName.departureMono,        size: 26,   letterSpacingEm: 0.04)
        case .valueMono:
            return GsFontSpec(name: GsFontName.departureMono,        size: 11,   letterSpacingEm: 0.08)
        case .chipText:
            return GsFontSpec(name: GsFontName.departureMono,        size: 10.5, letterSpacingEm: 0.12)
        case .navItem:
            return GsFontSpec(name: GsFontName.departureMono,        size: 10,   letterSpacingEm: 0.14)
        case .fabText:
            // `FontWeight.Medium` on Departure Mono → single-weight file, fall back to Regular.
            return GsFontSpec(name: GsFontName.departureMono,        size: 11,   letterSpacingEm: 0.20)

        // JetBrains Mono
        case .body:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 12)
        case .bodyMedium:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 11.5)
        case .kvValue:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 11)
        case .host:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 10)
        case .logTs:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 9)
        case .logLevel:
            return GsFontSpec(name: GsFontName.departureMono,        size: 9.5,  letterSpacingEm: 0.12)
        case .logMsg:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 10.5,                         lineHeight: 16)

        // Material baseline
        case .bodyLarge:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 14)
        case .bodySmall:
            return GsFontSpec(name: GsFontName.jetBrainsMono,        size: 11)
        case .titleLarge:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 22)
        case .titleMedium:
            return GsFontSpec(name: GsFontName.spaceGroteskBold,     size: 17)
        case .titleSmall:
            return GsFontSpec(name: GsFontName.departureMono,        size: 11,   letterSpacingEm: 0.15)
        case .labelLarge:
            return GsFontSpec(name: GsFontName.departureMono,        size: 11,   letterSpacingEm: 0.15)
        case .labelMedium:
            return GsFontSpec(name: GsFontName.departureMono,        size: 10.5, letterSpacingEm: 0.14)
        case .labelSmall:
            return GsFontSpec(name: GsFontName.departureMono,        size: 9.5,  letterSpacingEm: 0.12)
        }
    }
}

/// Concrete resolved style: font file, size, optional tracking + line-height.
struct GsFontSpec {
    let name: String
    let size: CGFloat
    /// Compose `em` units; converted to points (`em * size`) when applied.
    let letterSpacingEm: CGFloat
    /// Compose `lineHeight` in `sp`; applied via `.lineSpacing(lineHeight - size)`.
    let lineHeight: CGFloat?

    init(name: String, size: CGFloat, letterSpacingEm: CGFloat = 0, lineHeight: CGFloat? = nil) {
        self.name = name
        self.size = size
        self.letterSpacingEm = letterSpacingEm
        self.lineHeight = lineHeight
    }

    /// Tracking in points (SwiftUI `.tracking` is in points, not em).
    var trackingPoints: CGFloat { letterSpacingEm * size }

    /// Extra leading to add via `.lineSpacing(_:)` (SwiftUI `lineSpacing` is
    /// gap between lines, i.e. `lineHeight - fontSize`).
    var extraLineSpacing: CGFloat? {
        guard let lh = lineHeight else { return nil }
        return max(0, lh - size)
    }

    /// SwiftUI `Font` for use in non-Text contexts (buttons, labels, etc.).
    var font: Font { .custom(name, size: size) }
}

// MARK: - Text.gsFont(_:) — apply a named style

extension Text {
    /// Apply a named Ghoststream text style to this `Text`:
    ///   Text("GHOSTSTREAM").gsFont(.brand)
    func gsFont(_ style: GsFont) -> some View {
        let s = style.spec
        return self
            .font(.custom(s.name, size: s.size))
            .tracking(s.trackingPoints)
            .lineSpacing(s.extraLineSpacing ?? 0)
    }
}

// MARK: - Typography — Font instances for non-Text call sites

/// Mirror of `GsText` / `GsTypography` for places that need a raw `Font`
/// (e.g. `TextField`, `Button(...).font(Typography.body)`).
/// Letter-spacing and line-height are NOT baked in — use `Text.gsFont(_:)`
/// whenever tracking matters.
enum Typography {
    // GsText — Space Grotesk
    static let brand         = GsFont.brand.spec.font
    static let specTitle     = GsFont.specTitle.spec.font
    static let stateHeadline = GsFont.stateHeadline.spec.font
    static let profileName   = GsFont.profileName.spec.font
    static let clientName    = GsFont.clientName.spec.font
    static let statValue     = GsFont.statValue.spec.font
    static let hint          = GsFont.hint.spec.font

    // GsText — Departure Mono
    static let labelMono      = GsFont.labelMono.spec.font
    static let labelMonoSmall = GsFont.labelMonoSmall.spec.font
    static let labelMonoTiny  = GsFont.labelMonoTiny.spec.font
    static let hdrMeta        = GsFont.hdrMeta.spec.font
    static let ticker         = GsFont.ticker.spec.font
    static let valueMono      = GsFont.valueMono.spec.font
    static let chipText       = GsFont.chipText.spec.font
    static let navItem        = GsFont.navItem.spec.font
    static let fabText        = GsFont.fabText.spec.font

    // GsText — JetBrains Mono
    static let body       = GsFont.body.spec.font
    static let bodyMedium = GsFont.bodyMedium.spec.font
    static let kvValue    = GsFont.kvValue.spec.font
    static let host       = GsFont.host.spec.font
    static let logTs      = GsFont.logTs.spec.font
    static let logLevel   = GsFont.logLevel.spec.font
    static let logMsg     = GsFont.logMsg.spec.font

    // GsTypography — Material baseline
    static let bodyLarge   = GsFont.bodyLarge.spec.font
    static let bodySmall   = GsFont.bodySmall.spec.font
    static let titleLarge  = GsFont.titleLarge.spec.font
    static let titleMedium = GsFont.titleMedium.spec.font
    static let titleSmall  = GsFont.titleSmall.spec.font
    static let labelLarge  = GsFont.labelLarge.spec.font
    static let labelMedium = GsFont.labelMedium.spec.font
    static let labelSmall  = GsFont.labelSmall.spec.font
}
