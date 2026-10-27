//
//  Glass.swift
//  GhostStream
//
//  Liquid Glass lives only on the controls layer (tab bar, toolbar buttons,
//  primary action, header chips). iOS 26 gets the real thing; iOS 17–18 keep
//  today's look (material / filled buttons). Content cards stay opaque.
//

import PhantomUI
import SwiftUI

extension View {
    /// Glass behind a custom floating control (header chip, round button).
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Secondary action: `.glass` on iOS 26, bordered before.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// iOS 26 floats a glass tab bar over content; before that the bar stays
    /// opaque in the app background, as it was.
    @ViewBuilder
    func legacyTabBarBackground(_ color: Color) -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            toolbarBackground(color, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }

    /// Under a floating bottom action: scrolled content fades into the
    /// background instead of showing through a see-through glass button.
    func bottomActionFade(_ color: Color) -> some View {
        background {
            // 24 pt fade above the bar, solid behind the button and below.
            VStack(spacing: 0) {
                LinearGradient(colors: [color.opacity(0), color], startPoint: .top, endPoint: .bottom)
                    .frame(height: 24)
                color
            }
            .padding(.top, -24)
            .ignoresSafeArea()
        }
    }

    /// Opaque content card: elevated background, hairline, 26 pt corners.
    func gsCardBackground(_ C: GsColorSet, radius: CGFloat = 26) -> some View {
        background(C.bgElev, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(C.hair, lineWidth: 1)
            )
    }
}

/// Full-width primary action floating above the tab bar (Connect /
/// Disconnect, «Новый клиент»). Prominent = tinted glass; otherwise plain
/// glass (e.g. while reconnecting).
struct GlassPrimaryButton: View {
    let title: String
    let systemImage: String
    var tint: Color
    var prominent: Bool = true
    let action: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        let button = Button(action: action) {
            Label(title.uppercased(), systemImage: systemImage)
                .font(.custom(GsFontName.departureMono, size: 12))
                .tracking(2.4)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(prominent ? C.bg : C.bone)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 40)
        }
        .buttonBorderShape(.capsule)
        .tint(tint)

        if #available(iOS 26, *) {
            if prominent {
                button.buttonStyle(.glassProminent)
            } else {
                button.buttonStyle(.glass)
            }
        } else {
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
    }
}
