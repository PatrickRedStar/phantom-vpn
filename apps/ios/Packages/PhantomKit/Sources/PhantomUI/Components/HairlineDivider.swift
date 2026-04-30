//
//  HairlineDivider.swift
//  GhostStream
//
//  Thin 1pt divider using the current theme's `hair` color.
//

import SwiftUI

/// A 1-point-high horizontal divider rendered in the active palette's
/// `hair` color. Use between rows inside a `GhostCard`, or between
/// sections that sit on the same background.
public struct HairlineDivider: View {
    @Environment(\.gsColors) private var C

    /// Creates a new hairline divider. Expands to full available width.
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(C.hair)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

#if DEBUG
struct HairlineDivider_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            Text("Above").foregroundColor(.white)
            HairlineDivider()
            Text("Below").foregroundColor(.white)
        }
        .padding()
        .background(Color(hex: 0xFF0A0908))
        .environment(\.gsColors, .dark)
        .previewLayout(.sizeThatFits)
    }
}
#endif
