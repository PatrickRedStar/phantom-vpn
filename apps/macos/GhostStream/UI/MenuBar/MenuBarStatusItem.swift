//
//  MenuBarStatusItem.swift
//  GhostStream (macOS)
//
//  Значок в строке меню (mockup.html): монохромный template-призрак,
//  система сама красит его под светлую/тёмную строку. Залитый — VPN
//  подключён, контурный — нет. Оба ассета одного размера, ширина не прыгает.
//

import PhantomKit
import SwiftUI

public struct MenuBarStatusItem: View {

    public let state: ConnState

    public init(state: ConnState) {
        self.state = state
    }

    public var body: some View {
        Image(state == .connected ? "MenuBarGhost" : "MenuBarGhostOutline")
            .accessibilityLabel("GhostStream — \(state.title)")
    }
}
