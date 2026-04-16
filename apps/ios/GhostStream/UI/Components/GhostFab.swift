//
//  GhostFab.swift
//  GhostStream
//
//  Big pill-shaped primary action button (the dashboard CONNECT /
//  DISCONNECT affordance). Filled = active/live, outline = idle.
//

import SwiftUI

/// A large pill-shaped primary action button.
///
/// - `text`: label rendered with `GsFont.fabText` (11pt, +0.20em
///   spacing, ALL CAPS intended by caller).
/// - `outline`: when `true`, paints transparent fill + signal border
///   (used for the "CONNECT" idle state). When `false`, solid signal
///   fill + bone text (used for "DISCONNECT" while live).
/// - `action`: invoked on tap.
struct GhostFab: View {

    var text: String
    var outline: Bool = false
    var tint: Color? = nil
    var action: () -> Void

    @Environment(\.gsColors) private var C
    @State private var pressed = false

    var body: some View {
        let accent = tint ?? C.signal
        Button {
            action()
        } label: {
            Text(text)
                .gsFont(.fabText)
                .foregroundStyle(outline ? accent : C.bone)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(
                    Capsule(style: .continuous)
                        .fill(outline ? Color.clear : accent)
                )
                .overlay(
                    Capsule(style: .continuous)
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

/// Convenience: builds a `GhostFab` from a `VpnState` that performs the
/// correct action (start when disconnected, stop otherwise).
struct VpnConnectFab: View {

    let state: VpnState
    let onStart: () -> Void
    let onStop:  () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        let (label, outline, tint) = decoration(for: state, C: C)
        GhostFab(text: label, outline: outline, tint: tint) {
            switch state {
            case .disconnected, .error:
                onStart()
            case .connecting, .connected, .disconnecting:
                onStop()
            }
        }
    }

    private func decoration(
        for state: VpnState,
        C: GsColorSet
    ) -> (String, Bool, Color) {
        switch state {
        case .disconnected:  return ("CONNECT",       true,  C.signal)
        case .connecting:    return ("CONNECTING…",   false, C.warn)
        case .connected:     return ("DISCONNECT",    false, C.signal)
        case .disconnecting: return ("DISCONNECTING…", false, C.warn)
        case .error:         return ("RETRY",         true,  C.danger)
        }
    }
}

#Preview("GhostFab") {
    VStack(spacing: 12) {
        GhostFab(text: "CONNECT", outline: true) {}
        GhostFab(text: "DISCONNECT") {}
        VpnConnectFab(state: .disconnected, onStart: {}, onStop: {})
        VpnConnectFab(state: .connecting, onStart: {}, onStop: {})
        VpnConnectFab(state: .connected(since: Date(), serverName: "nl"), onStart: {}, onStop: {})
    }
    .padding()
    .background(Color.black)
    .gsTheme(override: .dark)
}
