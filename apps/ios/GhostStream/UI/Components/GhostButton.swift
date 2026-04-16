//
//  GhostButton.swift
//  GhostStream
//
//  Themed button primitives. Two variants:
//    - `.primary`   → filled `signal` background, `bg` text
//    - `.secondary` → transparent background, `hair` border, `bone` text
//

import SwiftUI

/// Visual variant of `GhostButton`.
public enum GhostButtonVariant {
    /// Filled signal (lime) background with dark text — used for positive actions.
    case primary
    /// Transparent background with hair border — used for secondary actions.
    case secondary
}

/// A minimal themed button that stamps a label inside a rounded rect.
/// Uses `GsFont.fabText` (Departure Mono, letterspaced) to match the rest
/// of the design language.
public struct GhostButton: View {
    private let title: String
    private let variant: GhostButtonVariant
    private let isEnabled: Bool
    private let action: () -> Void

    @Environment(\.gsColors) private var C

    /// Creates a themed button.
    /// - Parameters:
    ///   - title: Label text. Will be stamped uppercase with the `fabText` style.
    ///   - variant: `.primary` for filled, `.secondary` for outlined.
    ///   - isEnabled: When `false` the button dims to 50% and is unresponsive.
    ///   - action: Tap handler.
    public init(
        _ title: String,
        variant: GhostButtonVariant = .primary,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.variant = variant
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: { if isEnabled { action() } }) {
            Text(title.uppercased())
                .gsFont(.fabText)
                .foregroundColor(foreground)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(background)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    // MARK: - Styling

    private var foreground: Color {
        switch variant {
        case .primary:   return C.bg
        case .secondary: return C.bone
        }
    }

    private var background: Color {
        switch variant {
        case .primary:   return C.signal
        case .secondary: return Color.clear
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary:   return C.signalDim
        case .secondary: return C.hair
        }
    }
}

#if DEBUG
struct GhostButton_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            GhostButton("ADD PROFILE", variant: .primary)        { }
            GhostButton("SCAN QR",     variant: .secondary)      { }
            GhostButton("DISABLED",    variant: .primary,
                        isEnabled: false)                        { }
        }
        .padding()
        .background(Color(hex: 0xFF0A0908))
        .environment(\.gsColors, .dark)
        .previewLayout(.sizeThatFits)
    }
}
#endif
