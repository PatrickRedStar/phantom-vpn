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
            // POPOVER-LOOP fix (июль 2026): раньше пульс запускался через
            // `withAnimation(.repeatForever) { dim = true }` в onAppear.
            // Такая транзакция накрывает ВСЁ, что меняется в том же
            // проходе — при первом рендере внутри MenuBarExtra(.window)
            // это раскладка самого окна попапа, и анимация «шторки»
            // наследовала repeatForever: попап бесконечно выезжал/заезжал
            // (тот же класс бага, что «phantom popover» Wave 5, 763edb68).
            // `.animation(_, value:)` скоупит анимацию строго на opacity
            // этого сабтри и в window-layout не протекает.
            .animation(
                pulse
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : nil,
                value: dim
            )
            .onAppear {
                dim = pulse
            }
            .onChange(of: pulse) { _, isOn in
                dim = isOn
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
