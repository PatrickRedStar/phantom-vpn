//
//  AdminClientDetailPanel.swift
//  GhostStream (macOS)
//
//  Right-hand detail column of the ADMIN tab: traffic sparkline, recent
//  destinations and subscription actions for the selected client. Data is
//  fetched lazily per selection via the shared PhantomKit `AdminViewModel`.
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

struct AdminClientDetailPanel: View {

    let vm: AdminViewModel
    let client: AdminClient
    let onStatus: (String, Bool) -> Void
    let onDelete: () -> Void

    @Environment(\.gsColors) private var C

    @State private var stats: [ClientStat] = []
    @State private var logs: [ClientLog] = []
    @State private var detailLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                meta
                section(L("admin.detail.traffic"))
                sparkline
                section(L("admin.detail.destinations"))
                destinations
                section(L("admin.detail.subscription"))
                subscriptionBlock
                actions
            }
            .padding(16)
        }
        .background(C.bgElev)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
        .task(id: client.name) {
            await loadDetail()
        }
    }

    // MARK: - Blocks

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            Text(client.name)
                .font(.custom("SpaceGrotesk-Bold", size: 18))
                .foregroundStyle(C.bone)
            AdminStatusChip(chip: AdminClientRow(client: client, selected: false).chip)
            Spacer()
        }
    }

    @ViewBuilder
    private var meta: some View {
        Text("fp \(shortFingerprint) · \(client.tunAddr) · \(client.createdAt.prefix(10))")
            .font(.custom("JetBrainsMono-Regular", size: 10))
            .foregroundStyle(C.textFaint)
            .padding(.top, 4)
    }

    private var shortFingerprint: String {
        guard client.fingerprint.count > 12 else { return client.fingerprint }
        return "\(client.fingerprint.prefix(4))…\(client.fingerprint.suffix(4))"
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.custom("DepartureMono-Regular", size: 9))
            .tracking(0.16 * 9)
            .foregroundStyle(C.textFaint)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var sparkline: some View {
        ZStack {
            if stats.count >= 2 {
                TrafficSparkline(samples: stats, color: C.signal)
            } else {
                Text(detailLoading ? "…" : L("admin.detail.no_stats"))
                    .font(.custom("JetBrainsMono-Regular", size: 10))
                    .foregroundStyle(C.textFaint)
            }
        }
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(C.bg)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
    }

    @ViewBuilder
    private var destinations: some View {
        if logs.isEmpty {
            Text(detailLoading ? "…" : L("admin.detail.no_logs"))
                .font(.custom("JetBrainsMono-Regular", size: 10))
                .foregroundStyle(C.textFaint)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(logs.suffix(8).reversed().enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 6) {
                        Text(Self.timeOnly(entry.ts))
                            .foregroundStyle(C.textFaint)
                        Text("\(entry.dst):\(entry.port)")
                            .foregroundStyle(C.bone)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(entry.proto) · \(AdminConsoleFormat.bytes(entry.bytes))")
                            .foregroundStyle(C.textDim)
                    }
                    .font(.custom("JetBrainsMono-Regular", size: 10))
                }
            }
        }
    }

    @ViewBuilder
    private var subscriptionBlock: some View {
        VStack(spacing: 0) {
            kvRow(
                L("admin.detail.sub.state"),
                client.expiresAt == nil
                    ? L("admin.subscription.perpetual")
                    : AdminConsoleFormat.subscriptionShort(client.expiresAt)
            )
            kvRow(L("admin.detail.last_seen"), AdminConsoleFormat.lastSeen(client.lastSeenSecs))
            kvRow("RX", AdminConsoleFormat.bytes(client.bytesRx))
            kvRow("TX", AdminConsoleFormat.bytes(client.bytesTx))
        }
    }

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(C.textFaint)
            Spacer()
            Text(value)
                .foregroundStyle(C.bone)
        }
        .font(.custom("JetBrainsMono-Regular", size: 10.5))
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Rectangle().fill(C.hair).frame(height: 1)
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                actionButton(L("admin.action.extend30"), style: .signal) {
                    await mutate(L("admin.status.extended")) {
                        try await vm.manageSubscription(name: client.name, action: "extend", days: 30)
                    }
                }
                actionButton(L("admin.action.copy_ghs"), style: .plain) {
                    do {
                        let ghs = try await vm.getConnString(name: client.name)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ghs, forType: .string)
                        onStatus(L("admin.status.ghs_copied"), true)
                    } catch {
                        onStatus(error.localizedDescription, false)
                    }
                }
            }
            HStack(spacing: 8) {
                actionButton(
                    client.enabled ? L("admin.action.disable") : L("admin.action.enable"),
                    style: .warn
                ) {
                    await mutate(client.enabled ? L("admin.status.disabled") : L("admin.status.enabled")) {
                        try await vm.setEnabled(name: client.name, enabled: !client.enabled)
                    }
                }
                actionButton(L("admin.action.delete"), style: .danger) {
                    onDelete()
                }
            }
        }
        .padding(.top, 14)
    }

    private enum ActionStyle { case signal, plain, warn, danger }

    private func actionButton(
        _ title: String,
        style: ActionStyle,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.12 * 9.5)
                .foregroundStyle(foreground(for: style))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(style == .signal ? C.signal : Color.clear)
                .overlay(Rectangle().stroke(border(for: style), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foreground(for style: ActionStyle) -> Color {
        switch style {
        case .signal: return C.bg
        case .plain:  return C.textDim
        case .warn:   return C.warn
        case .danger: return C.danger
        }
    }

    private func border(for style: ActionStyle) -> Color {
        switch style {
        case .signal: return C.signal
        case .plain:  return C.hairBold
        case .warn:   return C.warn.opacity(0.4)
        case .danger: return C.danger.opacity(0.4)
        }
    }

    // MARK: - Data

    private func mutate(_ successMessage: String, _ op: () async throws -> Void) async {
        do {
            try await op()
            onStatus(successMessage, true)
            await loadDetail()
        } catch {
            onStatus(error.localizedDescription, false)
        }
    }

    private func loadDetail() async {
        detailLoading = true
        defer { detailLoading = false }
        async let statsTask = try? vm.getClientStats(name: client.name)
        async let logsTask = try? vm.getClientLogs(name: client.name)
        let (fetchedStats, fetchedLogs) = await (statsTask, logsTask)
        stats = fetchedStats ?? []
        logs = fetchedLogs ?? []
    }

    private static func timeOnly(_ ts: Int64) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

// MARK: - Sparkline

/// Filled polyline of per-sample total traffic (rx+tx deltas between
/// consecutive samples, normalised to the panel height).
struct TrafficSparkline: View {
    let samples: [ClientStat]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = normalisedPoints(in: geo.size)
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    for p in points { path.addLine(to: p) }
                    if let last = points.last {
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    }
                    path.closeSubpath()
                }
                .fill(color.opacity(0.08))

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for p in points.dropFirst() { path.addLine(to: p) }
                }
                .stroke(color, lineWidth: 1.5)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
    }

    private func normalisedPoints(in size: CGSize) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        // Counters are cumulative — chart the per-interval delta.
        var deltas: [Double] = []
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]
            let rx = max(0, cur.bytesRx - prev.bytesRx)
            let tx = max(0, cur.bytesTx - prev.bytesTx)
            deltas.append(Double(rx + tx))
        }
        let maxV = max(deltas.max() ?? 1, 1)
        let stepX = size.width / CGFloat(max(1, deltas.count - 1))
        return deltas.enumerated().map { idx, v in
            CGPoint(
                x: CGFloat(idx) * stepX,
                y: size.height - CGFloat(v / maxV) * size.height * 0.9 - size.height * 0.05
            )
        }
    }
}
