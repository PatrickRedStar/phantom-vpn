//
//  LogsView.swift
//  GhostStream
//
//  Live log tail view. Filter chip row (ALL/TRACE/DEBUG/INFO/WARN/ERROR +
//  CLEAR + SHARE), newest-first log list, bottom fade to the nav bar.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Root Logs screen.
struct LogsView: View {

    @Environment(\.gsColors) private var C
    @State private var vm = LogsViewModel()
    @State private var shareItem: ShareItem?
    @State private var showClearConfirmation = false
    @State private var userPinnedScroll = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                filterRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                statusBanner
                logList
            }

            // Bottom fade so the last log line doesn't crash into the nav.
            VStack {
                Spacer()
                LinearGradient(
                    colors: [C.bg.opacity(0), C.bg],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .allowsHitTesting(false)
            }
        }
        .searchable(
            text: $vm.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: L("native.logs.search")
        )
        .confirmationDialog(
            L("native.logs.clear.confirm.title"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(L("chip_clear"), role: .destructive) {
                vm.clear()
            }
            Button(L("general.cancel"), role: .cancel) {}
        } message: {
            Text(L("native.logs.clear.confirm.message"))
        }
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    // MARK: - Header

    private var header: some View {
        ScreenHeader(
            brand: NSLocalizedString("brand_tail", comment: ""),
            meta: metaText,
            pulse: isLive,
            pulseColor: statusColor
        )
    }

    private var metaText: String {
        let n = vm.allLogs.count
        if n >= 1000 {
            return String(
                format: L("native.logs.lines.format"),
                headerStateText,
                String(format: "%.1fk", Double(n) / 1000)
            )
        }
        return String(format: L("native.logs.lines.format"), headerStateText, "\(n)")
    }

    private var headerStateText: String {
        if vm.hasIpcError { return L("native.logs.ipc.error") }
        return isLive ? L("native.logs.live") : vm.statusLabel
    }

    private var isLive: Bool {
        guard !vm.hasIpcError else { return false }
        if case .connected = vm.tunnelState { return true }
        return false
    }

    private var statusColor: Color {
        if vm.hasIpcError { return C.danger }
        switch vm.tunnelState {
        case .connected: return C.signal
        case .connecting, .disconnecting: return C.warn
        case .error: return C.danger
        case .disconnected: return C.textFaint
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = vm.statusMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: vm.hasIpcError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .gsFont(.hdrMeta)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(statusColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(statusColor.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(statusColor.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Filter row

    private var filterRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 74), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(LogFilter.allCases, id: \.self) { f in
                chip(filter: f)
            }
            logChip(L("chip_clear"), active: false, accent: C.danger) {
                showClearConfirmation = true
            }

            logChip(L("chip_share"), active: false, accent: C.signal) {
                if let url = vm.shareFileURL(range: 500) {
                    shareItem = ShareItem(url: url)
                }
            }
        }
    }

    private func chip(filter f: LogFilter) -> some View {
        logChip(f.rawValue, active: vm.filter == f, accent: C.signal) {
            vm.filter = f
        }
    }

    private func logChip(
        _ text: String,
        active: Bool,
        accent: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(text.uppercased())
                .gsFont(.chipText)
                .foregroundStyle(active ? C.bg : accent)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .frame(maxWidth: .infinity, minHeight: 42)
                .padding(.horizontal, 4)
                .background(active ? accent : Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(active ? accent : C.hairBold, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Log list

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Render newest-first so appended rows appear at the top.
                    Color.clear
                        .frame(height: 1)
                        .id("__head__")
                    ForEach(vm.visibleLogs) { entry in
                        LogFrameRow(entry: entry)
                            .id(entry.tsUnixMs)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 80)
            }
            .onChange(of: vm.visibleLogs.count) { _, _ in
                guard !userPinnedScroll else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("__head__", anchor: .top)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6).onChanged { _ in
                    userPinnedScroll = true
                }
            )
        }
    }
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

// MARK: - LogFrameRow

private struct LogFrameRow: View {

    let entry: LogFrame

    @Environment(\.gsColors) private var C

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(levelColor)
                .frame(width: 2)
            Text(LogsViewModel.formatTs(entry.tsUnixMs))
                .gsFont(.logTs)
                .foregroundStyle(C.textFaint)
                .frame(width: 54, alignment: .leading)
            Text(LogsViewModel.levelBadge(entry.level))
                .gsFont(.labelMonoSmall)
                .foregroundStyle(levelColor)
                .frame(width: 32, height: 16, alignment: .center)
                .background(levelColor.opacity(badgeOpacity))
            Text(entry.msg)
                .gsFont(.logMsg)
                .foregroundStyle(messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .padding(.trailing, 4)
        .background(rowBackground)
    }

    private var levelColor: Color {
        switch entry.level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return C.danger
        case "WARN", "WARNING":          return C.warn
        case "INFO", "OK":               return C.signal
        case "DEBUG":                    return C.blueDebug
        case "TRACE":                    return C.textFaint
        default:                         return C.textDim
        }
    }

    private var badgeOpacity: Double {
        switch entry.level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return 0.16
        case "WARN", "WARNING":          return 0.12
        case "INFO", "OK":               return 0.10
        case "DEBUG":                    return 0.12
        case "TRACE":                    return 0.08
        default:                         return 0.08
        }
    }

    private var rowBackground: Color {
        switch entry.level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return C.danger.opacity(0.08)
        case "WARN", "WARNING":          return C.warn.opacity(0.05)
        default:                         return Color.clear
        }
    }

    private var messageColor: Color {
        switch entry.level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return C.danger.opacity(0.85)
        case "WARN", "WARNING":          return C.warn.opacity(0.80)
        case "DEBUG":                    return C.blueDebug.opacity(0.70)
        case "TRACE":                    return C.textFaint
        default:                         return C.bone
        }
    }
}

// MARK: - Share sheet plumbing

private struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Preview

#Preview("Logs — Populated") {
    let vm = LogsViewModel()
    // Seed synthetic entries for preview (no Rust bridge calls in canvas).
    // The real VM will keep polling; the preview is frozen.
    return NavigationStack { LogsView() }
        .gsTheme(override: .dark)
        .onAppear {
            _ = vm // silence unused
        }
}
