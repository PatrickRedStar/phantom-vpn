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

/// Eight equal-width bars with smooth, slightly random animated heights.
///
/// - `active`: when `false`, bars freeze at low flat levels (no shimmer).
///   When `true`, heights shuffle every 700ms while visible.
/// - `barCount`: defaults to 8 (matches MAX_N_STREAMS / typical mux).
/// - `height`: total strip height (default 70pt).
struct MuxBars: View {

    var active: Bool = true
    var barCount: Int = 8
    var height: CGFloat = 70

    @Environment(\.gsColors) private var C
    @State private var heights: [CGFloat] = []

    var body: some View {
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
        .task(id: active) {
            // 700ms shimmer tick while active.
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
        heights = makeHeights(active: active)
    }

    private func makeHeights(active: Bool) -> [CGFloat] {
        (0..<barCount).map { _ in
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
