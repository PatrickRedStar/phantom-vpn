//
//  StatCard.swift
//  GhostStream
//
//  Small card showing a single numeric stat: ALL-CAPS mono label on top,
//  bold value below, optional unit appended to the value row.
//

import SwiftUI

/// A compact card: label (`labelMono`) + value (`statValue`) + unit.
/// Fills the width of its container and has an internal hairline.
struct StatCard: View {

    let title: String
    let value: String
    var unit: String? = nil
    var valueColor: Color? = nil

    @Environment(\.gsColors) private var C

    var body: some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(title.uppercased())
                    .gsFont(.labelMono)
                    .foregroundStyle(C.textFaint)
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(value)
                        .gsFont(.statValue)
                        .foregroundStyle(valueColor ?? C.bone)
                    if let unit {
                        Text(unit)
                            .gsFont(.labelMonoSmall)
                            .foregroundStyle(C.textDim)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("StatCard") {
    HStack(spacing: 10) {
        StatCard(title: "RX", value: "1.23", unit: "Mbps")
        StatCard(title: "TX", value: "0.45", unit: "Mbps")
    }
    .padding()
    .background(Color.black)
    .gsTheme(override: .dark)
}
