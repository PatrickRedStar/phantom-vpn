//
//  AboutView.swift
//  GhostStream (macOS)
//
//  Custom About panel — phosphor logo + version. Used as content for
//  CommandGroup(replacing: .appInfo).
//

import PhantomUI
import SwiftUI

public struct AboutView: View {

    @Environment(\.gsColors) private var C

    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            ScopeRingGlyph(size: 80, signal: C.signal, dim: C.signalDim)
            Text("Ghoststream")
                .font(.custom("SpaceGrotesk-Bold", size: 26))
                .tracking(-0.02 * 26)
                .foregroundStyle(C.bone)
            HStack(spacing: 8) {
                Text("v0.23.0")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.18 * 11)
                    .foregroundStyle(C.signal)
                Text("·")
                    .foregroundStyle(C.textFaint)
                Text("PHOSPHOR")
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.18 * 10)
                    .foregroundStyle(C.textFaint)
            }
            Text("warm-black + phosphor-lime")
                .font(.custom("JetBrainsMono-Regular", size: 11))
                .foregroundStyle(C.textDim)
                .padding(.top, 4)
            HairlineDivider().padding(.horizontal, 80).padding(.vertical, 12)
            Text("© 2026 GhostStream")
                .font(.custom("JetBrainsMono-Regular", size: 10))
                .foregroundStyle(C.textFaint)
        }
        .frame(width: 360, height: 280)
        .padding(24)
        .background(C.bg)
    }
}
