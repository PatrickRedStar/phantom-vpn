//
//  MuxBars.swift
//  GhostStream
//
//  Small horizontal bar strip — eight signal-lime bars with animated
//  heights, hinting at the multi-stream mux (§4.6 of the spec).
//
//  TODO: Replace the synthetic height engine with real per-stream byte
//  rates once `PhantomBridge.stats()` exposes per-TLS-stream counters.
//

import SwiftUI

/// Equal-width bars with smooth, slightly random animated heights.
///
/// - `active`: when `false`, bars freeze at low flat levels (no shimmer).
///   When `true`, heights shuffle every 700ms while visible (unless
///   `activityLevels` is supplied, in which case real values are used).
/// - `barCount`: defaults to 8 (matches MAX_N_STREAMS / typical mux).
/// - `activityLevels`: optional per-bar real activity (0.0–1.0, 16 elements
///   from `StatusFrame.streamActivity`). When non-nil the synthetic shimmer
///   is replaced with the actual per-stream values.
/// - `height`: total strip height (default 70pt).
public struct MuxBars: View {

    public var active: Bool
    public var barCount: Int
    /// Real per-stream activity from `StatusFrame.streamActivity`. When
    /// supplied the synthetic random shimmer is bypassed.
    public var activityLevels: [Float]?
    public var height: CGFloat

    public init(
        active: Bool = true,
        barCount: Int = 8,
        activityLevels: [Float]? = nil,
        height: CGFloat = 70
    ) {
        self.active = active
        self.barCount = barCount
        self.activityLevels = activityLevels
        self.height = height
    }

    @Environment(\.gsColors) private var C
    @State private var heights: [CGFloat] = []

    public var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<barCount, id: \.self) { idx in
                GeometryReader { geo in
                    let h = heights.indices.contains(idx)
                        ? heights[idx]
                        : 0.1
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [C.signal, C.signalDim],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: geo.size.height * h)
                    }
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .onAppear(perform: resetHeights)
        .onChange(of: active) { _, _ in resetHeights() }
        .onChange(of: activityLevels) { _, _ in
            // When real data arrives, update without animation to reflect
            // the true per-stream state immediately.
            if activityLevels != nil { resetHeights() }
        }
        .task(id: active) {
            // 700ms shimmer tick while active — skipped when real levels
            // are provided (the onChange above handles updates).
            guard activityLevels == nil else { return }
            while active && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { break }
                withAnimation(.easeInOut(duration: 0.55)) {
                    heights = makeHeights(active: active)
                }
            }
        }
    }

    private func resetHeights() {
        withAnimation(.easeInOut(duration: 0.4)) {
            heights = makeHeights(active: active)
        }
    }

    private func makeHeights(active: Bool) -> [CGFloat] {
        if let levels = activityLevels {
            // Use real per-stream activity, clamped to a safe range so bars
            // are always visible when a stream exists (min 0.08).
            return (0..<barCount).map { idx in
                guard idx < levels.count else { return CGFloat(0.08) }
                let v = levels[idx]
                return active
                    ? CGFloat(max(0.08, min(1.0, v)))
                    : 0.08
            }
        }
        return (0..<barCount).map { _ in
            active
                ? CGFloat.random(in: 0.20...0.95)
                : 0.08
        }
    }
}

#Preview("MuxBars") {
    VStack(spacing: 20) {
        MuxBars(active: true)
        MuxBars(active: false)
    }
    .padding()
    .background(Color.black)
    .gsTheme(override: .dark)
}
