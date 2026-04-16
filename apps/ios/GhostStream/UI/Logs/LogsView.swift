//
//  LogsView.swift
//  GhostStream
//
//  Live log tail view. Filter chip row (ALL/TRACE/DEBUG/INFO/WARN/ERROR +
//  SHARE + CLEAR), auto-scrolling log list, bottom fade to the nav bar.
//

import SwiftUI

/// Root Logs screen.
struct LogsView: View {

    @Environment(\.gsColors) private var C
    @State private var vm = LogsViewModel()
    @State private var shareItem: ShareItem?
    @State private var userPinnedScroll = false

    var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                filterRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
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
        .onAppear { vm.startPolling() }
        .onDisappear { vm.stopPolling() }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("TAIL")
                .gsFont(.brand)
                .foregroundStyle(C.bone)
            Spacer()
            HStack(spacing: 6) {
                Text(metaText)
                    .gsFont(.hdrMeta)
                    .foregroundStyle(C.textFaint)
                PulseDot(color: C.signal, size: 5)
            }
        }
    }

    private var metaText: String {
        let n = vm.allLogs.count
        if n >= 1000 {
            return "LIVE · \(String(format: "%.1fk", Double(n) / 1000)) LINES"
        }
        return "LIVE · \(n) LINES"
    }

    // MARK: - Filter row

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LogFilter.allCases, id: \.self) { f in
                    chip(filter: f)
                }
                Button {
                    vm.clear()
                } label: {
                    chipBody(text: "CLEAR", active: false, accent: C.danger)
                }
                .buttonStyle(.plain)

                Button {
                    if let url = vm.shareFileURL(range: 500) {
                        shareItem = ShareItem(url: url)
                    }
                } label: {
                    chipBody(text: "SHARE", active: false, accent: C.signal)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(filter f: LogFilter) -> some View {
        Button {
            vm.filter = f
        } label: {
            chipBody(text: f.rawValue, active: vm.filter == f, accent: C.signal)
        }
        .buttonStyle(.plain)
    }

    private func chipBody(text: String, active: Bool, accent: Color) -> some View {
        Text(text)
            .gsFont(.chipText)
            .foregroundStyle(active ? accent : C.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(active ? accent.opacity(0.20) : Color.clear)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(active ? accent.opacity(0.5) : C.hair, lineWidth: 1)
            )
    }

    // MARK: - Log list

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Render oldest-first; the list grows downward. We
                    // auto-scroll to the newest when appended, unless
                    // the user has scrolled manually.
                    ForEach(vm.visibleLogs) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.seq)
                    }
                    // Tail sentinel — used for scroll-to-bottom.
                    Color.clear
                        .frame(height: 1)
                        .id("__tail__")
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 80)
            }
            .onChange(of: vm.visibleLogs.count) { _, _ in
                guard !userPinnedScroll else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("__tail__", anchor: .bottom)
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

// MARK: - LogEntryRow

private struct LogEntryRow: View {

    let entry: LogEntry

    @Environment(\.gsColors) private var C

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(LogsViewModel.formatTs(entry.ts))
                .gsFont(.logTs)
                .foregroundStyle(C.textFaint)
                .frame(width: 60, alignment: .leading)
            Text(LogsViewModel.levelBadge(entry.level))
                .gsFont(.logLevel)
                .foregroundStyle(levelColor)
                .frame(width: 36, alignment: .leading)
            Text(entry.message)
                .gsFont(.logMsg)
                .foregroundStyle(messageColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return C.danger
        case "WARN", "WARNING":          return C.warn
        case "INFO", "OK":               return C.textDim
        case "DEBUG":                    return C.blueDebug
        case "TRACE":                    return C.textFaint
        default:                         return C.textDim
        }
    }

    private var messageColor: Color {
        switch entry.level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return C.danger
        case "WARN", "WARNING":          return C.warn
        case "DEBUG":                    return C.blueDebug
        default:                         return C.bone.opacity(0.85)
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
