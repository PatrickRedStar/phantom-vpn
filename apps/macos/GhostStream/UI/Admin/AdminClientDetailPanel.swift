//
//  AdminClientDetailPanel.swift
//  GhostStream (macOS)
//
//  Инспектор «Админа»: сведения о выбранном клиенте, трафик за сутки,
//  последние адреса, ссылка с QR и действия. Статистика и адреса
//  подгружаются при выборе клиента.
//

import AppKit
import CoreImage.CIFilterBuiltins
import PhantomKit
import PhantomUI
import SwiftUI

struct AdminClientDetailPanel: View {

    let vm: AdminViewModel
    let client: AdminClient
    let isOwn: Bool
    let onRequest: (AdminRequest) -> Void
    let onStatus: (String, Bool) -> Void

    @Environment(\.gsColors) private var C

    @State private var stats: [ClientStat] = []
    @State private var logs: [ClientLog] = []
    @State private var loading = false
    @State private var link: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: GsSpace.xs) {
                    Text(isOwn ? String(format: L("adm.you"), client.name) : client.name)
                        .gsType(.headline)
                    AdminClientStatus(client: client)
                        .gsType(.caption)
                        .foregroundStyle(C.textDim)
                }
                LabeledContent(L("adm.i.address")) {
                    Text(client.tunAddr.split(separator: "/").first.map(String.init) ?? "")
                        .font(GsType.mono.font)
                }
                LabeledContent(L("adm.col.access"), value: AdminFormat.access(client.expiresAt).text)
                if !client.connected, let ago = AdminFormat.ago(client.lastSeenSecs) {
                    LabeledContent(L("adm.i.seen"), value: ago)
                }
                LabeledContent(L("adm.i.received"), value: AdminFormat.bytes(client.bytesRx))
                LabeledContent(L("adm.i.sent"), value: AdminFormat.bytes(client.bytesTx))
                LabeledContent(L("adm.i.role"),
                               value: L(client.isAdmin ? "adm.i.role.admin" : "adm.i.role.user"))
                if let created = Self.created(client.createdAt) {
                    LabeledContent(L("adm.i.created"), value: created)
                }
            }

            Section(L("adm.i.traffic")) {
                if stats.count >= 2 {
                    TrafficSparkline(samples: stats, color: C.signal)
                        .frame(height: 56)
                } else {
                    noData
                }
            }

            Section(L("adm.i.destinations")) {
                if logs.isEmpty {
                    noData
                } else {
                    ForEach(Array(logs.suffix(6).reversed().enumerated()), id: \.offset) { _, entry in
                        LabeledContent {
                            Text(AdminFormat.bytes(entry.bytes))
                        } label: {
                            Text(entry.dst)
                                .font(GsType.mono.font)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            Section {
                Text(L("adm.link.warning"))
                    .gsType(.caption)
                    .foregroundStyle(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: GsSpace.s) {
                    // Короткие подписи: в узком инспекторе длинные обрезались.
                    Button(L("adm.copy")) { onRequest(.copyLink) }
                        .gsGlassButton()
                    if link == nil {
                        Button(L("adm.qr")) { Task { await loadLink() } }
                            .gsGlassButton()
                    }
                }
                if let link {
                    QRCodeView(link: link)
                        .frame(maxWidth: .infinity)
                }
            } header: {
                Text(L("adm.i.link"))
            }

            Section {
                Button(L("adm.extend30")) { onRequest(.extend30) }
                if client.enabled {
                    Button(L("adm.disable")) { onRequest(.disable) }
                } else {
                    Button(L("adm.enable")) { onRequest(.enable) }
                }
                if client.isAdmin {
                    Button(L("adm.revoke_admin")) { onRequest(.revokeAdmin) }
                } else {
                    Button(L("adm.make_admin")) { onRequest(.makeAdmin) }
                }
                Button(L("adm.delete"), role: .destructive) { onRequest(.delete) }
                    .foregroundStyle(C.danger)
            }
            .buttonStyle(.borderless)
            // Без цвета borderless-кнопки выглядели выключенными.
            .foregroundStyle(C.signal)
        }
        .formStyle(.grouped)
        // Фон палитры, как у основной области, — без серой полосы инспектора.
        .scrollContentBackground(.hidden)
        .background(C.bg)
        .gsType(.body)
        .task(id: client.name) {
            link = nil
            await loadDetail()
        }
    }

    private var noData: some View {
        Text(loading ? "…" : L("adm.i.no_data"))
            .foregroundStyle(C.textDim)
    }

    // MARK: - Data

    private func loadDetail() async {
        #if DEBUG
        if DebugDemo.isActive {
            stats = AdminDemo.stats
            logs = AdminDemo.logs
            return
        }
        #endif
        loading = true
        defer { loading = false }
        async let statsTask = try? vm.getClientStats(name: client.name)
        async let logsTask = try? vm.getClientLogs(name: client.name)
        let (fetchedStats, fetchedLogs) = await (statsTask, logsTask)
        stats = fetchedStats ?? []
        logs = fetchedLogs ?? []
    }

    private func loadLink() async {
        do {
            link = try await vm.getConnString(name: client.name)
        } catch {
            onStatus(error.localizedDescription, false)
        }
    }

    private static func created(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) ?? parser.date(from: iso + "Z") else { return nil }
        return date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year())
    }
}

// MARK: - QR

/// QR ghs://-ссылки (CoreImage), на светлой подложке — чтобы читался
/// камерой и в тёмной теме.
struct QRCodeView: View {
    let link: String

    var body: some View {
        if let image = Self.image(link) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(10)
                .frame(width: 168, height: 168)
                .background(.white, in: RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous))
                .accessibilityLabel(L("adm.i.link"))
        }
    }

    static func image(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

// MARK: - Sparkline

/// Трафик между соседними замерами (счётчики накопительные), нормирован
/// по высоте.
struct TrafficSparkline: View {
    let samples: [ClientStat]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = points(in: geo.size)
            ZStack {
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.15))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .padding(.vertical, GsSpace.xs)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let deltas = zip(samples, samples.dropFirst()).map { prev, cur in
            Double(max(0, cur.bytesRx - prev.bytesRx) + max(0, cur.bytesTx - prev.bytesTx))
        }
        let maxV = max(deltas.max() ?? 1, 1)
        let stepX = size.width / CGFloat(max(1, deltas.count - 1))
        return deltas.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * stepX, y: size.height * (0.95 - 0.9 * CGFloat(v / maxV)))
        }
    }
}
