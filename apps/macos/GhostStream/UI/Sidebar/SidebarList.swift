//
//  SidebarList.swift
//  GhostStream (macOS)
//
//  Sidebar — pixel-matched to sections 02..05 of the design HTML:
//   • Brand header  18×16pt: ScopeRingGlyph 22pt + "Ghoststream"
//                  titleMedium + "v0.23" labelMonoTiny faint right.
//   • Hairline divider.
//   • Channel list  14pt top padding, items 9×12pt with grid
//                  [ico 14pt][ALL CAPS labelMono 11pt 0.18em][⌘N kbd].
//                  Active = signal text + signal.opacity(0.07) bg.
//   • Spacer.
//   • Hairline divider.
//   • SidebarProfileBlock pinned at the bottom (own 14pt padding).
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct SidebarList: View {

    @Environment(\.gsColors) private var C
    @Environment(AppRouter.self) private var router

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            brandHeader
            HairlineDivider()
            channelList
                .padding(.top, 14)
                .padding(.horizontal, 10)
            Spacer()
            HairlineDivider()
            SidebarProfileBlock()
                .padding(.bottom, 14)
        }
        .background(C.bgElev)
    }

    @ViewBuilder
    private var brandHeader: some View {
        HStack(spacing: 10) {
            ScopeRingGlyph(size: 22, signal: C.signal, dim: C.signalDim)
            Text("Ghoststream")
                .font(.custom("SpaceGrotesk-Bold", size: 14))
                .tracking(-0.01 * 14)
                .foregroundStyle(C.bone)
            Spacer()
            Text("v0.23")
                .font(.custom("DepartureMono-Regular", size: 9))
                .tracking(0.18 * 9)
                .foregroundStyle(C.textFaint)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var channelList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SidebarChannel.allCases) { channel in
                channelRow(channel)
            }
        }
    }

    @ViewBuilder
    private func channelRow(_ channel: SidebarChannel) -> some View {
        let active = router.selectedChannel == channel
        Button {
            router.select(channel)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: channel.sfSymbol)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 14, height: 14)
                    .opacity(active ? 1.0 : 0.7)
                Text(String(localized: channel.localizedKey))
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.18 * 11)
                    .foregroundStyle(active ? C.signal : C.textDim)
                Spacer()
                Text(verbatim: "⌘\(String(channel.hotkey))")
                    .font(.custom("DepartureMono-Regular", size: 9.5))
                    .tracking(0.10 * 9.5)
                    .foregroundStyle(C.textFaint)
            }
            .foregroundStyle(active ? C.signal : C.textDim)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(active ? C.signal.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(channel.hotkey), modifiers: .command)
    }
}
