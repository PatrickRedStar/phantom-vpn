//
//  ScopeChart.swift
//  GhostStream
//
//  Oscilloscope-style dual-trace chart: RX (signal/lime with fill) and
//  TX (warn/orange, no fill). Uses SwiftUI.Canvas for the retro vector
//  look (§4.5 of the spec).
//

import SwiftUI

/// Time window presets for the scope. Tapping the chart label cycles
/// through these (1m → 5m → 30m → 1h → 1m…).
enum ScopeWindow: Int, CaseIterable, Hashable {
    case m1  = 60
    case m5  = 300
    case m30 = 1800
    case h1  = 3600

    /// Label rendered in the top-right of the scope card.
    var label: String {
        switch self {
        case .m1:  return "1m"
        case .m5:  return "5m"
        case .m30: return "30m"
        case .h1:  return "1h"
        }
    }

    /// Next window in the cycle.
    var next: ScopeWindow {
        let all = ScopeWindow.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}

/// A dual-trace line-graph canvas.
///
/// - `rxSamples`: per-second RX byte rate (already rolling-delta'd).
/// - `txSamples`: per-second TX byte rate.
/// - `height`: vertical size (default 90pt).
///
/// Both sample arrays are expected to be aligned: index 0 = oldest,
/// last = newest. Empty arrays render the grid only.
struct ScopeChart: View {

    let rxSamples: [Double]
    let txSamples: [Double]
    var height: CGFloat = 90

    @Environment(\.gsColors) private var C

    var body: some View {
        Canvas { ctx, size in
            // Grid: 3 horizontal hairlines at 25% intervals.
            let grid = C.hair
            for i in 1...3 {
                let y = size.height * CGFloat(i) * 0.25
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(grid), lineWidth: 0.5)
            }

            // Normalise both traces against their combined peak so the
            // two are directly comparable.
            let peak = max(
                rxSamples.max() ?? 0,
                txSamples.max() ?? 0,
                1.0
            )

            // RX trace — fill gradient + stroke + soft glow.
            if let rxPath = makePath(
                samples: rxSamples,
                in: size,
                peak: peak,
                closedFill: true
            ) {
                let fill = Gradient(colors: [
                    C.signal.opacity(0.35),
                    C.signal.opacity(0.0),
                ])
                ctx.fill(
                    rxPath,
                    with: .linearGradient(
                        fill,
                        startPoint: .zero,
                        endPoint: CGPoint(x: 0, y: size.height)
                    )
                )
            }
            if let rxLine = makePath(
                samples: rxSamples,
                in: size,
                peak: peak,
                closedFill: false
            ) {
                // Glow: wide, translucent.
                ctx.stroke(rxLine, with: .color(C.signal.opacity(0.35)), lineWidth: 3)
                ctx.stroke(rxLine, with: .color(C.signal), lineWidth: 1.25)
            }

            // TX trace — stroke only, orange.
            if let txLine = makePath(
                samples: txSamples,
                in: size,
                peak: peak,
                closedFill: false
            ) {
                ctx.stroke(txLine, with: .color(C.warn.opacity(0.30)), lineWidth: 3)
                ctx.stroke(txLine, with: .color(C.warn), lineWidth: 1.0)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    /// Build a Path from samples. Returns `nil` when there are fewer
    /// than two samples.
    private func makePath(
        samples: [Double],
        in size: CGSize,
        peak: Double,
        closedFill: Bool
    ) -> Path? {
        guard samples.count >= 2 else { return nil }
        let w = size.width
        let h = size.height
        let denom = max(CGFloat(samples.count - 1), 1)
        var path = Path()
        for (i, v) in samples.enumerated() {
            let x = CGFloat(i) / denom * w
            // Invert y — SwiftUI 0 is top.
            let y = h - CGFloat(v / peak) * h
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else      { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        if closedFill {
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.closeSubpath()
        }
        return path
    }
}

#Preview("ScopeChart") {
    let rx = (0..<60).map { i in sin(Double(i) / 5.0) * 0.5 + 0.6 + Double.random(in: 0...0.2) }
    let tx = (0..<60).map { i in cos(Double(i) / 7.0) * 0.3 + 0.4 + Double.random(in: 0...0.15) }
    return ScopeChart(rxSamples: rx, txSamples: tx)
        .padding()
        .background(Color.black)
        .gsTheme(override: .dark)
}
