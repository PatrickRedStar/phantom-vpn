import SwiftUI
import PhantomUI

struct NativeSectionCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.gsColors) private var C

    var body: some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(C.bgElev.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(C.hair, lineWidth: 1)
                    )
            )
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
                        .font(.body.weight(.semibold))
                        .foregroundStyle(role == .destructive ? C.danger : C.bone)
                    if let subtitle {
                        Text(subtitle)
                            .font(.footnote)
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

struct NativeStatusPill: View {
    let text: String
    let tone: DashboardTone

    @Environment(\.gsColors) private var C

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule(style: .continuous))
    }

    private var color: Color {
        switch tone {
        case .neutral: return C.textDim
        case .success: return C.signal
        case .warning: return C.warn
        case .danger:  return C.danger
        }
    }
}

struct NativeBottomAction: View {
    let title: String
    let tone: DashboardTone
    let action: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .foregroundStyle(filled ? C.bg : C.bone)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(filled ? color : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(color, lineWidth: filled ? 0 : 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var filled: Bool {
        tone == .success || tone == .danger
    }

    private var color: Color {
        switch tone {
        case .neutral: return C.signal
        case .success: return C.signal
        case .warning: return C.warn
        case .danger:  return C.danger
        }
    }
}
