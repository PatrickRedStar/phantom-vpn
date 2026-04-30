//
//  KeyboardShortcutHint.swift
//  GhostStream (macOS)
//
//  Small `.kbd` visual — Departure-Mono token in a hairline box.
//

import PhantomUI
import SwiftUI

public struct KeyboardShortcutHint: View {

    public let label: String

    public init(_ label: String) {
        self.label = label
    }

    @Environment(\.gsColors) private var C

    public var body: some View {
        Text(label)
            .font(Typography.labelMonoTiny)
            .foregroundStyle(C.textDim)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(C.bgElev2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(C.hair, lineWidth: 1)
            )
    }
}

#Preview("KBD") {
    HStack(spacing: 8) {
        KeyboardShortcutHint("⌘0")
        KeyboardShortcutHint("⌘K")
        KeyboardShortcutHint("⌘⇧C")
    }
    .padding()
    .background(Color.black)
    .gsTheme(override: .dark)
}
