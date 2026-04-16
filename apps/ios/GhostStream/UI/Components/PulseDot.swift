//
//  PulseDot.swift
//  GhostStream
//
//  Small pulsing circle indicator (1.6s cycle). Colour typically driven
//  by VPN state: signal = connected, warn = connecting, danger = error,
//  textFaint = disconnected.
//

import SwiftUI

/// A tiny circle that fades 1.0 → 0.25 → 1.0 in a 1.6s loop.
///
/// - `color`: fill (default signal lime — caller typically overrides
///   based on `VpnState`).
/// - `size`: diameter (default 5pt).
/// - `pulse`: set to `false` to freeze the dot at full opacity.
struct PulseDot: View {

    var color: Color
    var size: CGFloat = 5
    var pulse: Bool = true

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? (dim ? 0.25 : 1.0) : 1.0)
            .onAppear {
                guard pulse else { return }
                withAnimation(
                    .easeInOut(duration: 0.8)
                    .repeatForever(autoreverses: true)
                ) {
                    dim = true
                }
            }
    }
}

/// Maps a `VpnState` to the canonical pulse colour used across screens.
@MainActor
func pulseColor(for state: VpnState, colors C: GsColorSet) -> Color {
    switch state {
    case .connected:     return C.signal
    case .connecting,
         .disconnecting: return C.warn
    case .error:         return C.danger
    case .disconnected:  return C.textFaint
    }
}

#Preview("PulseDot") {
    HStack(spacing: 20) {
        PulseDot(color: .green)
        PulseDot(color: .orange, size: 8)
        PulseDot(color: .red, pulse: false)
    }
    .padding()
    .background(Color.black)
}
