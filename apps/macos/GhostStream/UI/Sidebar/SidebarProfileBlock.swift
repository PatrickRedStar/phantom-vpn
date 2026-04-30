//
//  SidebarProfileBlock.swift
//  GhostStream (macOS)
//
//  Pinned profile picker at the bottom of the sidebar, pixel-matched to
//  sections 02..05 of the design HTML:
//
//   • lblmono "ACTIVE PROFILE"  9.5pt 0.18em faint, bottom-margin 8pt.
//   • profile-pill — 1pt hairBold border, bgElev2 fill, padding 10×12pt.
//      grid: [name profileName 13pt -0.01em + meta body 10.5pt faint][rtt
//      mono 11pt signal][chev textDim 14pt].
//   • Outer container: 14pt horizontal padding, 14pt top padding.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct SidebarProfileBlock: View {

    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles
    @Environment(VpnStateManager.self) private var stateMgr

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVE PROFILE")
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.18 * 9.5)
                .foregroundStyle(C.textFaint)

            profilePill
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var profilePill: some View {
        Menu {
            if profiles.profiles.isEmpty {
                Button("No profiles") {}
                    .disabled(true)
            } else {
                ForEach(profiles.profiles) { profile in
                    Button {
                        profiles.setActive(id: profile.id)
                    } label: {
                        HStack {
                            Text(profile.name)
                            if profiles.activeId == profile.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            profilePillContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Choose active profile")
    }

    @ViewBuilder
    private var profilePillContent: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profiles.activeProfile?.name ?? "—")
                    .font(.custom("SpaceGrotesk-Bold", size: 13))
                    .tracking(-0.01 * 13)
                    .foregroundStyle(C.bone)
                if let host = profiles.activeProfile?.serverAddr, !host.isEmpty {
                    Text(host)
                        .font(.custom("JetBrainsMono-Regular", size: 10.5))
                        .foregroundStyle(C.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let rtt = stateMgr.statusFrame.rttMs {
                Text("\(rtt)ms")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.05 * 11)
                    .foregroundStyle(C.signal)
            }
            Image(systemName: "chevron.up.chevron.down")
                .foregroundStyle(C.textDim)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(C.bgElev2)
        .overlay(
            Rectangle().stroke(C.hairBold, lineWidth: 1)
        )
    }
}
