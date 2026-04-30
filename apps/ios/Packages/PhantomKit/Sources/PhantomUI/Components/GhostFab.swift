//
//  GhostFab.swift
//  PhantomUI
//
//  Big pill-shaped primary action button (the dashboard CONNECT /
//  DISCONNECT affordance). Filled = active/live, outline = idle.
//

import SwiftUI

/// A large rectangular primary action button.
///
/// - `text`: label rendered with `GsFont.fabText` (11pt, +0.20em
///   spacing, ALL CAPS intended by caller).
/// - `outline`: when `true`, paints transparent fill + signal border
///   (used for the "CONNECT" idle state). When `false`, solid signal
///   fill + background-coloured text (used for "DISCONNECT" while live).
/// - `action`: invoked on tap.
public struct GhostFab: View {

    public var text: String
    public var outline: Bool
    public var tint: Color?
    public var action: () -> Void

    public init(
        text: String,
        outline: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.outline = outline
        self.tint = tint
        self.action = action
    }

    @Environment(\.gsColors) private var C
    @State private var pressed = false

    public var body: some View {
        let accent = tint ?? C.signal
        Button {
            action()
        } label: {
            Text(text)
                .gsFont(.fabText)
                .foregroundStyle(outline ? accent : C.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(outline ? Color.clear : accent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(accent, lineWidth: outline ? 1.5 : 0)
                )
                .scaleEffect(pressed ? 0.98 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }
}

#Preview("GhostFab") {
    VStack(spacing: 12) {
        GhostFab(text: "CONNECT", outline: true) {}
        GhostFab(text: "DISCONNECT") {}
        GhostFab(text: "RETRY", outline: true, tint: .red) {}
    }
    .padding()
    .background(Color.black)
    .gsTheme(override: .dark)
}
