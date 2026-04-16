//
//  GhostToggle.swift
//  GhostStream
//
//  Themed replacement for SwiftUI's default `Toggle`.
//  OFF: `bgElev2` track, `textFaint` thumb. ON: `signal` track, `bone` thumb.
//

import SwiftUI

/// A small custom toggle switch matching the Ghoststream design language.
///
/// Preferred over `Toggle` because SwiftUI's `.toggleStyle(.switch)` paints
/// the `accentColor`/system tint and refuses to respect the custom warm-cream
/// `bone` color for the thumb.
public struct GhostToggle: View {
    @Binding private var isOn: Bool
    private let onLabel: String?

    @Environment(\.gsColors) private var C

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 22
    private let thumbSize: CGFloat = 18
    private let thumbPadding: CGFloat = 2

    /// Creates a toggle bound to `isOn`. `onLabel` is an optional accessibility hint.
    public init(isOn: Binding<Bool>, onLabel: String? = nil) {
        self._isOn = isOn
        self.onLabel = onLabel
    }

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? C.signal : C.bgElev2)
                .overlay(
                    Capsule()
                        .stroke(isOn ? C.signalDim : C.hair, lineWidth: 1)
                )
                .frame(width: trackWidth, height: trackHeight)

            Circle()
                .fill(C.bone)
                .frame(width: thumbSize, height: thumbSize)
                .padding(.horizontal, thumbPadding)
                .shadow(color: Color.black.opacity(0.25), radius: 1, y: 1)
        }
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement()
        .accessibilityLabel(onLabel ?? "Toggle")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

#if DEBUG
struct GhostToggle_Previews: PreviewProvider {
    struct Demo: View {
        @State var off = false
        @State var on  = true
        @Environment(\.gsColors) private var C
        var body: some View {
            VStack(spacing: 16) {
                HStack { Text("OFF").foregroundColor(C.bone); Spacer(); GhostToggle(isOn: $off) }
                HStack { Text("ON").foregroundColor(C.bone);  Spacer(); GhostToggle(isOn: $on)  }
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
