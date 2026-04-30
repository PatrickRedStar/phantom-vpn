//
//  GhostToggle.swift
//  GhostStream
//
//  Themed replacement for SwiftUI's default `Toggle`.
//  OFF: transparent track, `textFaint` square knob. ON: signal-dim track,
//  `signal` square knob with glow.
//

import PhantomUI
import SwiftUI

/// A small custom toggle switch matching the Ghoststream design language.
///
/// Preferred over `Toggle` because SwiftUI's `.toggleStyle(.switch)` paints
/// the `accentColor`/system tint and refuses to respect the custom warm-cream
/// `bone` color for the thumb.
public struct GhostToggle: View {
    @Binding private var isOn: Bool
    private let label: String

    @Environment(\.gsColors) private var C

    private let trackWidth: CGFloat = 40
    private let trackHeight: CGFloat = 22
    private let thumbSize: CGFloat = 14
    private let thumbPadding: CGFloat = 2

    /// Creates a toggle bound to `isOn`. `onLabel` is an optional accessibility hint.
    public init(isOn: Binding<Bool>, onLabel: String? = nil) {
        self._isOn = isOn
        self.label = onLabel ?? "Toggle"
    }

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Rectangle()
                .fill(isOn ? C.signalDim.opacity(0.40) : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(isOn ? C.signal : C.hairBold, lineWidth: 1)
                )
                .frame(width: trackWidth, height: trackHeight)

            Rectangle()
                .fill(isOn ? C.signal : C.textDim)
                .frame(width: thumbSize, height: thumbSize)
                .padding(.horizontal, thumbPadding)
                .shadow(color: isOn ? C.signal.opacity(0.45) : Color.clear, radius: 4)
        }
        .animation(.easeInOut(duration: 0.18), value: isOn)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) {
                Text(label)
            }
        }
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
