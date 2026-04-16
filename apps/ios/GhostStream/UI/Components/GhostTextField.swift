//
//  GhostTextField.swift
//  GhostStream
//
//  Themed text-field wrapper with `bgElev2` background, `hair` border,
//  `bone` text, `textFaint` placeholder.
//

import SwiftUI

/// A plain text field styled to match the Ghoststream design language.
public struct GhostTextField: View {
    @Binding private var text: String
    private let placeholder: String
    private let keyboardType: UIKeyboardType
    private let autocapitalization: TextInputAutocapitalization
    private let isSecure: Bool
    private let onCommit: (() -> Void)?

    @Environment(\.gsColors) private var C

    /// Creates a themed text field.
    /// - Parameters:
    ///   - text: Two-way binding to the underlying string.
    ///   - placeholder: Placeholder string, rendered in `textFaint` color.
    ///   - keyboardType: iOS keyboard type. Defaults to `.default`.
    ///   - autocapitalization: Default `.never` for IP / CIDR / keys.
    ///   - isSecure: If `true` renders with `SecureField` for hidden input.
    ///   - onCommit: Called when the user hits return.
    public init(
        _ placeholder: String,
        text: Binding<String>,
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .never,
        isSecure: Bool = false,
        onCommit: (() -> Void)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.keyboardType = keyboardType
        self.autocapitalization = autocapitalization
        self.isSecure = isSecure
        self.onCommit = onCommit
    }

    public var body: some View {
        Group {
            if isSecure {
                SecureField("", text: $text, prompt: placeholderText)
            } else {
                TextField("", text: $text, prompt: placeholderText)
                    .onSubmit { onCommit?() }
            }
        }
        .font(Typography.body)
        .foregroundColor(C.bone)
        .tint(C.signal)
        .keyboardType(keyboardType)
        .textInputAutocapitalization(autocapitalization)
        .autocorrectionDisabled(true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(C.bgElev2)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(C.hair, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var placeholderText: Text {
        Text(placeholder)
            .font(Typography.body)
            .foregroundColor(C.textFaint)
    }
}

#if DEBUG
struct GhostTextField_Previews: PreviewProvider {
    struct Demo: View {
        @State var name = ""
        @State var pass = ""
        @Environment(\.gsColors) private var C
        var body: some View {
            VStack(spacing: 12) {
                GhostTextField("Имя профиля", text: $name)
                GhostTextField("Пароль", text: $pass, isSecure: true)
            }
            .padding()
            .background(C.bg)
        }
    }
    static var previews: some View {
        Demo()
            .environment(\.gsColors, .dark)
            .previewLayout(.sizeThatFits)
    }
}
#endif
