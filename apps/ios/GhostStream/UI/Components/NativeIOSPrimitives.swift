import SwiftUI
import PhantomUI

struct NativeSectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.gsColors) private var C

    var body: some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .gsCardBackground(C)
    }
}

/// Caption above a card: «ПРОФИЛИ · 2».
struct SectionLabel: View {
    let text: String
    @Environment(\.gsColors) private var C

    var body: some View {
        Text(text.uppercased())
            .gsFont(.labelMono)
            .foregroundStyle(C.textDim)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct NativeRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let role: ButtonRole?
    let action: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    @Environment(\.gsColors) private var C

    init(
        title: String,
        subtitle: String? = nil,
        role: ButtonRole? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.role = role
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        Button(role: role) {
            action?()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.custom(GsFontName.jetBrainsMono, size: 13))
                        .foregroundStyle(role == .destructive ? C.danger : C.bone)
                    if let subtitle {
                        Text(subtitle)
                            .font(.custom(GsFontName.jetBrainsMono, size: 10.5))
                            .foregroundStyle(C.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing()
                    .foregroundStyle(C.textFaint)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

extension NativeRow where Trailing == Image {
    init(
        title: String,
        subtitle: String? = nil,
        role: ButtonRole? = nil,
        action: (() -> Void)? = nil
    ) {
        self.init(title: title, subtitle: subtitle, role: role, action: action) {
            Image(systemName: "chevron.right")
        }
    }
}
