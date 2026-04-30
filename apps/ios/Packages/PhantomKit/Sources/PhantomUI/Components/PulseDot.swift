//
//  PulseDot.swift
//  PhantomUI
//
//  Small pulsing circle indicator (1.6s cycle). Colour driven by caller.
//

import SwiftUI

/// A tiny circle that fades 1.0 → 0.25 → 1.0 in a 1.6s loop.
///
/// - `color`: fill (default signal lime — caller typically overrides
///   based on `VpnState`).
/// - `size`: diameter (default 5pt).
/// - `pulse`: set to `false` to freeze the dot at full opacity.
public struct PulseDot: View {

    public var color: Color
    public var size: CGFloat
    public var pulse: Bool

    public init(color: Color, size: CGFloat = 5, pulse: Bool = true) {
        self.color = color
        self.size = size
        self.pulse = pulse
    }

    @State private var dim = false

    public var body: some View {
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

#Preview("PulseDot") {
    HStack(spacing: 20) {
        PulseDot(color: .green)
        PulseDot(color: .orange, size: 8)
        PulseDot(color: .red, pulse: false)
    }
    .padding()
    .background(Color.black)
}
