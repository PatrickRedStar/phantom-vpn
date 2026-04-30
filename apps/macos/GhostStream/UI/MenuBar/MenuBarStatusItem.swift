//
//  MenuBarStatusItem.swift
//  GhostStream (macOS)
//
//  Menu bar label — uses the brand `MenuBarIcon` asset (rendered from
//  `icons/v4-03-scope/ic_launcher_monochrome.svg` at 18/36/54 px) marked
//  as a template image so macOS auto-tints it to match the system menu
//  bar foreground (black on light, white on dark). A small coloured dot
//  beside the glyph reflects the current `ConnState` — macOS 14+ keeps
//  custom-colour SwiftUI shapes inside menu bar labels.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct MenuBarStatusItem: View {

    public let state: ConnState

    public init(state: ConnState) {
        self.state = state
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 18, height: 18)
            stateDot
        }
        .accessibilityLabel("GhostStream — \(accessibilityState)")
    }

    @ViewBuilder
    private var stateDot: some View {
        switch state {
        case .connected:
            Circle()
                .fill(Color(red: 0.77, green: 1.00, blue: 0.24))   // signal lime
                .frame(width: 5, height: 5)
        case .connecting, .reconnecting:
            Circle()
                .fill(Color(red: 1.00, green: 0.48, blue: 0.24))   // warn orange
                .frame(width: 5, height: 5)
        case .error:
            Circle()
                .fill(Color(red: 1.00, green: 0.29, blue: 0.24))   // danger red
                .frame(width: 5, height: 5)
        case .disconnected:
            EmptyView()
        }
    }

    private var accessibilityState: String {
        switch state {
        case .disconnected: return "Standby"
        case .connecting:   return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .connected:    return "Transmitting"
        case .error:        return "Error"
        }
    }
}

#Preview("MenuBarStatusItem") {
    HStack(spacing: 24) {
        MenuBarStatusItem(state: .disconnected)
        MenuBarStatusItem(state: .connecting)
        MenuBarStatusItem(state: .connected)
        MenuBarStatusItem(state: .error)
    }
    .padding()
    .background(Color.gray)
}
