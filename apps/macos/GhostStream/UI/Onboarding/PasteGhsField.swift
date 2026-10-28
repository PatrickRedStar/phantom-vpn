//
//  PasteGhsField.swift
//  GhostStream (macOS)
//
//  Поле для ссылки ghs:// в мастере: моноширинный многострочный ввод
//  в карточке макета (bgElev, волосяная рамка, радиус group).
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct PasteGhsField: View {

    @Binding var text: String
    @Environment(\.gsColors) private var C

    public init(text: Binding<String>) {
        self._text = text
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous)
        TextEditor(text: $text)
            .font(GsType.mono.font)
            .foregroundStyle(C.bone)
            .scrollContentBackground(.hidden)
            .padding(GsSpace.m)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    // +5: внутренний отступ строки NSTextView.
                    Text(L("welcome.paste.placeholder"))
                        .gsType(.mono)
                        .foregroundStyle(C.textFaint)
                        .padding(.leading, GsSpace.m + 5)
                        .padding(.top, GsSpace.m)
                        .allowsHitTesting(false)
                }
            }
            .background(C.bgElev, in: shape)
            .overlay(shape.stroke(C.hair, lineWidth: 1))
            .accessibilityLabel(L("welcome.paste.placeholder"))
    }
}
