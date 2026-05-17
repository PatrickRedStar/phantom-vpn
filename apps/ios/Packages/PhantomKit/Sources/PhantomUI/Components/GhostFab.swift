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
/// - `busy`: when `true`, renders a `ProgressView` overlay alongside
///   the label so callers can signal an in-flight action (e.g. the
///   menu-bar popover CANCEL state during a teardown). Added in
///   Round 5 (UI-R4-R07) — the previous Round 4 CANCEL pill had no
///   spinner so users couldn't tell whether a tap had landed when the
///   server stalls for the full 75s TLS deadline.
/// - `action`: invoked on tap.
public struct GhostFab: View {

    public var text: String
    public var outline: Bool
    public var tint: Color?
    public var busy: Bool
    public var action: () -> Void

    public init(
        text: String,
        outline: Bool = false,
        tint: Color? = nil,
        busy: Bool = false,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.outline = outline
        self.tint = tint
        self.busy = busy
        self.action = action
    }

    @Environment(\.gsColors) private var C
    @State private var pressed = false

    public var body: some View {
        let accent = tint ?? C.signal
        Button {
            action()
        } label: {
            HStack(spacing: 10) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        // Tint the spinner to the same accent as the
                        // label so the dual-element pill reads as one
                        // unit on both light and dark themes.
                        .tint(outline ? accent : C.bg)
                }
                Text(text)
                    .gsFont(.fabText)
                    .foregroundStyle(outline ? accent : C.bg)
            }
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
        GhostFab(text: "CANCEL", outline: true, tint: .orange, busy: true) {}
    }
    .padding()
    .background(Color.black)
    .gsTheme(override: .dark)
}
