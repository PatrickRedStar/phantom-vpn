//
//  GhostCard.swift
//  GhostStream
//
//  Reusable rounded-rectangle container. Hairline border + elevated
//  background. Active variant adds a lime left-edge glow (per spec §4.1).
//

import SwiftUI

/// A rounded card container with a hairline border and elevated fill.
///
/// - `active`: when `true`, paints the lime "tuned-in" left-edge glow
///   documented in the iOS UI spec (signalDim outer 6dp + signal inner
///   2dp, 18%–82% of card height).
/// - `bg` / `border`: override fill / stroke (defaults: `C.bgElev`,
///   `C.hair`).
/// - Corner radius: 6pt (matches Android `GhostCard` 6dp).
/// - Inner padding: 14 horizontal × 10 vertical.
public struct GhostCard<Content: View>: View {

    public var active: Bool
    public var bg: Color?
    public var border: Color?
    @ViewBuilder public var content: () -> Content

    public init(
        active: Bool = false,
        bg: Color? = nil,
        border: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.active = active
        self.bg = bg
        self.border = border
        self.content = content
    }

    @Environment(\.gsColors) private var C

    public var body: some View {
        let fill = bg ?? C.bgElev
        let stroke = border ?? C.hair

        ZStack(alignment: .leading) {
            // Background + hairline border.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(stroke, lineWidth: 1)
                )

            // Active left-edge glow: dim outer line + bright inner line,
            // both inset to 18%–82% of card height.
            if active {
                GeometryReader { geo in
                    let top = geo.size.height * 0.18
                    let bottom = geo.size.height * 0.18
                    let height = geo.size.height - top - bottom
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(C.signalDim.opacity(0.5))
                            .frame(width: 6, height: height)
                            .offset(x: 0, y: top)
                        Rectangle()
                            .fill(C.signal)
                            .frame(width: 2, height: height)
                            .offset(x: 2, y: top)
                    }
                }
                .allowsHitTesting(false)
            }

            // Active variant also gets a subtle lime wash.
            if active {
                LinearGradient(
                    colors: [C.signal.opacity(0.04), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .allowsHitTesting(false)
            }

            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("GhostCard") {
    VStack(spacing: 12) {
        GhostCard {
            Text("Idle card").foregroundStyle(.white)
        }
        GhostCard(active: true) {
            Text("Active card").foregroundStyle(.white)
        }
    }
    .padding()
    .background(Color.black)
    .gsTheme(override: .dark)
}
