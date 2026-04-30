//
//  GhostChrome.swift
//  PhantomUI
//
//  Shared Ghoststream chrome and controls ported from the Android Compose UI.
//

import SwiftUI

public struct ScreenHeader: View {
    public var brand: String
    public var meta: String?
    public var pulse: Bool
    public var pulseColor: Color?
    public var leadingAction: (() -> Void)?
    public var leadingLabel: String?

    @Environment(\.gsColors) private var C

    public init(
        brand: String,
        meta: String? = nil,
        pulse: Bool = false,
        pulseColor: Color? = nil,
        leadingLabel: String? = nil,
        leadingAction: (() -> Void)? = nil
    ) {
        self.brand = brand
        self.meta = meta
        self.pulse = pulse
        self.pulseColor = pulseColor
        self.leadingLabel = leadingLabel
        self.leadingAction = leadingAction
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            if let leadingAction {
                Button(action: leadingAction) {
                    Text(leadingLabel ?? "‹")
                        .gsFont(.labelMono)
                        .foregroundStyle(C.signal)
                        .frame(width: 32, height: 32)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(leadingLabel ?? "Back"))
            }

            tintedBrand
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 10)

            if let meta {
                HeaderMeta(
                    text: meta,
                    pulse: pulse,
                    pulseColor: pulseColor
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(C.hair)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var tintedBrand: some View {
        if let first = brand.first {
            let head = Text(String(first))
                .foregroundStyle(C.signal)
            let tail = Text(String(brand.dropFirst()))
                .foregroundStyle(C.bone)
            (head + tail).gsFont(.brand)
        } else {
            Text("").gsFont(.brand)
        }
    }
}

public struct HeaderMeta: View {
    public var text: String
    public var pulse: Bool
    public var pulseColor: Color?

    @Environment(\.gsColors) private var C

    public init(text: String, pulse: Bool = false, pulseColor: Color? = nil) {
        self.text = text
        self.pulse = pulse
        self.pulseColor = pulseColor
    }

    public var body: some View {
        HStack(spacing: 6) {
            if pulse {
                PulseDot(color: pulseColor ?? C.signal, size: 5, pulse: true)
            }
            Text(text.uppercased())
                .gsFont(.hdrMeta)
                .foregroundStyle(C.textFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

public struct GhostChip: View {
    public var text: String
    public var active: Bool
    public var accent: Color?
    public var action: () -> Void

    @Environment(\.gsColors) private var C

    public init(
        _ text: String,
        active: Bool = false,
        accent: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.text = text
        self.active = active
        self.accent = accent
        self.action = action
    }

    public var body: some View {
        let resolved = accent ?? C.signal
        Button(action: action) {
            Text(text.uppercased())
                .gsFont(.chipText)
                .foregroundStyle(active ? C.bg : resolved)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(active ? resolved : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(active ? resolved : C.hairBold, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

public struct DashedHairline: View {
    public var color: Color?
    public var dash: CGFloat
    public var gap: CGFloat

    @Environment(\.gsColors) private var C

    public init(color: Color? = nil, dash: CGFloat = 4, gap: CGFloat = 4) {
        self.color = color
        self.dash = dash
        self.gap = gap
    }

    public var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: proxy.size.width, y: 0))
            }
            .stroke(
                color ?? C.hair,
                style: StrokeStyle(lineWidth: 1, dash: [dash, gap])
            )
        }
        .frame(height: 1)
    }
}

public struct DashedGhostCard<Content: View>: View {
    public var action: (() -> Void)?
    @ViewBuilder public var content: () -> Content

    @Environment(\.gsColors) private var C

    public init(action: (() -> Void)? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.action = action
        self.content = content
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    inner
                }
                .buttonStyle(.plain)
            } else {
                inner
            }
        }
    }

    private var inner: some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(C.bgElev.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        C.hairBold,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 5])
                    )
            )
    }
}

public struct ThemeSwitch: View {
    @Binding public var selected: ThemeOverride
    @Environment(\.gsColors) private var C

    public init(selected: Binding<ThemeOverride>) {
        self._selected = selected
    }

    public var body: some View {
        GhostSegmentedSwitch(
            entries: [
                ("DRK", ThemeOverride.dark),
                ("LHT", ThemeOverride.light),
                ("SYS", ThemeOverride.system),
            ],
            selected: $selected
        )
    }
}

public struct LangSwitch: View {
    @Binding public var selected: String
    @Environment(\.gsColors) private var C

    public init(selected: Binding<String>) {
        self._selected = selected
    }

    public var body: some View {
        GhostSegmentedSwitch(
            entries: [("RU", "ru"), ("EN", "en"), ("SYS", "system")],
            selected: $selected
        )
    }
}

private struct GhostSegmentedSwitch<Value: Hashable>: View {
    var entries: [(String, Value)]
    @Binding var selected: Value

    @Environment(\.gsColors) private var C

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { idx, item in
                Button {
                    selected = item.1
                } label: {
                    Text(item.0)
                        .gsFont(.valueMono)
                        .foregroundStyle(selected == item.1 ? C.signal : C.textFaint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if idx < entries.count - 1 {
                    Text("·")
                        .gsFont(.valueMono)
                        .foregroundStyle(C.textFaint)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
    }
}

public struct GhostDialog<Content: View>: View {
    public var title: String
    public var message: String?
    public var primaryTitle: String
    public var secondaryTitle: String?
    public var primaryAction: () -> Void
    public var secondaryAction: (() -> Void)?
    @ViewBuilder public var content: () -> Content

    @Environment(\.gsColors) private var C

    public init(
        title: String,
        message: String? = nil,
        primaryTitle: String,
        secondaryTitle: String? = nil,
        primaryAction: @escaping () -> Void,
        secondaryAction: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.message = message
        self.primaryTitle = primaryTitle
        self.secondaryTitle = secondaryTitle
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.content = content
    }

    public var body: some View {
        ZStack {
            C.bg.opacity(0.76).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text(title.uppercased())
                    .gsFont(.brand)
                    .foregroundStyle(C.bone)

                if let message {
                    Text(message)
                        .gsFont(.body)
                        .foregroundStyle(C.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content()

                HStack(spacing: 10) {
                    if let secondaryTitle, let secondaryAction {
                        GhostFab(
                            text: secondaryTitle.uppercased(),
                            outline: true,
                            tint: C.textDim,
                            action: secondaryAction
                        )
                    }
                    GhostFab(text: primaryTitle.uppercased(), action: primaryAction)
                }
            }
            .padding(18)
            .background(C.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(C.hairBold, lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
    }
}

public struct GhostFullDialog<Content: View>: View {
    public var title: String
    public var meta: String?
    public var onClose: () -> Void
    @ViewBuilder public var content: () -> Content

    @Environment(\.gsColors) private var C

    public init(
        title: String,
        meta: String? = nil,
        onClose: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.meta = meta
        self.onClose = onClose
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                brand: title,
                meta: meta,
                leadingLabel: "✕",
                leadingAction: onClose
            )
            ScrollView {
                content()
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(C.bg.ignoresSafeArea())
    }
}
