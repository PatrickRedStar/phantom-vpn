//
//  AboutView.swift
//  GhostStream (macOS)
//
//  «О программе GhostStream»: иконка, версия и сборка из Info.plist,
//  ссылка на релизы. Открывается из меню приложения.
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct AboutView: View {

    @Environment(\.gsColors) private var C

    private static let releasesURL = URL(string: "https://github.com/PatrickRedStar/ghoststream-releases/releases")!

    public init() {}

    public var body: some View {
        VStack(spacing: GsSpace.s) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.bottom, GsSpace.s)
            Text(String(format: L("about.version"), UpdateChecker.currentVersion, UpdateChecker.currentBuild))
                .gsType(.headline)
                .foregroundStyle(C.bone)
                .textSelection(.enabled)
            Text(L("about.tagline"))
                .gsType(.caption)
                .foregroundStyle(C.textDim)
                .multilineTextAlignment(.center)
                .padding(.top, GsSpace.xs)
            Link(L("about.releases"), destination: Self.releasesURL)
                .gsType(.body)
                .foregroundStyle(C.signal)
                .padding(.top, GsSpace.m)
            Text(verbatim: "© 2026 GhostStream")
                .gsType(.caption)
                .foregroundStyle(C.textFaint)
                .padding(.top, GsSpace.l)
        }
        .padding(.horizontal, GsSpace.xxl)
        .padding(.top, GsSpace.xxl + GsSpace.s)
        .padding(.bottom, GsSpace.xl)
        .frame(width: 340)
        .background(C.bg)
    }
}
