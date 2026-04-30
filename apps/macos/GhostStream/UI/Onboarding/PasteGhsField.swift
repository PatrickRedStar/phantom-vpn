//
//  PasteGhsField.swift
//  GhostStream (macOS)
//
//  Multiline mono TextEditor — pixel-matched to section 06 of the design
//  HTML. The header row carries an ALL CAPS lblmono label on the left
//  ("connection string · ghs://") plus a char counter on the right.
//  The body uses JetBrainsMono 13pt against `bgElev2` with a hairBold
//  border at 1pt.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct PasteGhsField: View {

    @Binding var text: String
    @Environment(\.gsColors) private var C

    /// Soft cap shown next to the live char count (matches the HTML spec).
    private let softMax = 8_192

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CONNECTION STRING · GHS://")
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.18 * 10)
                    .foregroundStyle(C.textFaint)
                Spacer()
                Text(charCounter)
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.04 * 10)
                    .foregroundStyle(C.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(C.bg)
            .overlay(alignment: .bottom) {
                Rectangle().fill(C.hair).frame(height: 1)
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    HStack(spacing: 0) {
                        Text("ghs://")
                            .foregroundStyle(C.signal)
                        Text("…paste full connection string here…")
                            .foregroundStyle(C.textFaint)
                    }
                    .font(.custom("JetBrainsMono-Regular", size: 13))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                }

                TextEditor(text: $text)
                    .font(.custom("JetBrainsMono-Regular", size: 13))
                    .foregroundStyle(C.bone)
                    .scrollContentBackground(.hidden)
                    .background(C.bgElev2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            }
            .frame(minHeight: 120)
        }
        .background(C.bgElev2)
        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
    }

    private var charCounter: String {
        let n = text.count
        // Inject thin space group separator like "2 412 / 8 192".
        return "\(grouped(n)) / \(grouped(softMax))"
    }

    private func grouped(_ n: Int) -> String {
        let s = String(n)
        var result = ""
        for (i, ch) in s.reversed().enumerated() {
            if i != 0 && i % 3 == 0 { result = " " + result }
            result = String(ch) + result
        }
        return result
    }
}
