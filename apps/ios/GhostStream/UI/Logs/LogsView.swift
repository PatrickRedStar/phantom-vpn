//
//  LogsView.swift
//  GhostStream
//
//  Journal: level chips, newest-first lines in one card (repeats folded
//  into «×N», long-press copies), share + clear in the toolbar, native
//  search. History survives app restarts (LogsViewModel).
//

import PhantomKit
import PhantomUI
import SwiftUI
import UIKit

/// Root Logs screen.
struct LogsView: View {

    @Environment(\.gsColors) private var C
    @Bindable private var vm = LogsViewModel.shared
    @State private var shareItem: ShareItem?
    @State private var showClearConfirmation = false
    @State private var userPinnedScroll = false

    /// Chips per mockup — TRACE stays reachable through ВСЕ.
    private let filters: [LogFilter] = [.all, .debug, .info, .warn, .error]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Color.clear.frame(height: 0).id("__head__")
                    filterRow
                    statusBanner
                    logCard
                    Text(L("native.logs.footnote"))
                        .font(.custom(GsFontName.jetBrainsMono, size: 10))
                        .foregroundStyle(C.textFaint)
                        .padding(.horizontal, 8)
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
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
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(L("nav_logs"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    if let url = vm.shareFileURL(range: 500) {
                        shareItem = ShareItem(url: url)
                    }
                } label: {
                    Label(L("chip_share"), systemImage: "square.and.arrow.up")
                }
                .disabled(vm.allLogs.isEmpty)
                Button {
                    showClearConfirmation = true
                } label: {
                    Label(L("chip_clear"), systemImage: "trash")
                }
                .disabled(vm.allLogs.isEmpty)
            }
        }
        .logsSearch(text: $vm.searchText, prompt: L("native.logs.search"))
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
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    private var statusColor: Color {
        if vm.hasIpcError { return C.danger }
        switch vm.tunnelState {
        case .connected: return C.signal
        case .connecting, .reconnecting, .disconnecting: return C.warn
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
            .padding(12)
            .background(statusColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(statusColor.opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - Filter row

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters, id: \.self) { f in
                    let active = vm.filter == f
                    Button {
                        vm.filter = f
                    } label: {
                        Text(f.nativeTitle)
                            .gsFont(.chipText)
                            .foregroundStyle(active ? C.signal : C.textDim)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(active ? C.signal.opacity(0.16) : C.bgElev, in: Capsule())
                            .overlay(Capsule().stroke(active ? C.signal.opacity(0.5) : C.hair, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }

    // MARK: - Log list

    @ViewBuilder
    private var logCard: some View {
        let lines = LogsPresentation.collapsed(vm.visibleLogs)
        if !lines.isEmpty {
            LazyVStack(alignment: .leading, spacing: 9) {
                ForEach(lines) { line in
                    LogLineRow(line: line)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .gsCardBackground(C)
        }
    }
}

private func L(_ key: String) -> String {
    AppStrings.localized(key)
}

private extension LogFilter {
    var nativeTitle: String {
        switch self {
        case .all: return L("logs.filter.all")
        case .trace: return "TRACE"
        case .debug: return L("logs.filter.debug")
        case .info: return L("logs.filter.info")
        case .warn: return L("logs.filter.warn")
        case .error: return L("logs.filter.error")
        }
    }
}

private extension View {
    /// iOS 26: search collapses into a glass button in the toolbar (a
    /// bottom-bar placement hides behind the tab bar); before that, the
    /// classic drawer under the title.
    @ViewBuilder
    func logsSearch(text: Binding<String>, prompt: String) -> some View {
        if #available(iOS 26, *) {
            searchable(text: text, prompt: prompt)
                .searchToolbarBehavior(.minimize)
        } else {
            searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
        }
    }
}

// MARK: - LogLineRow

private struct LogLineRow: View {

    let line: LogLine

    @Environment(\.gsColors) private var C

    var body: some View {
        let entry = line.frame
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(LogsViewModel.formatTs(entry.tsUnixMs))
                .foregroundStyle(C.textDim)
            Text(LogsViewModel.levelBadge(entry.level))
                .font(.custom(GsFontName.departureMono, size: 10.5))
                .foregroundStyle(levelColor)
                .frame(width: 34, alignment: .leading)
            (Text(entry.msg).foregroundColor(C.bone)
                + Text(line.count > 1 ? "  ×\(line.count)" : "").foregroundColor(C.textDim))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.custom(GsFontName.jetBrainsMono, size: 10.5))
        .lineSpacing(2)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = LogsViewModel.format(entry)
            } label: {
                Label(L("logs.copy"), systemImage: "doc.on.doc")
            }
        }
    }

    private var levelColor: Color {
        switch entry.level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return C.danger
        case "WARN", "WARNING", "WRN":   return C.warn
        case "INFO", "OK", "INF":        return C.signal
        case "DEBUG", "DBG":             return C.blueDebug
        default:                         return C.textFaint
        }
    }

    private var entry: LogFrame { line.frame }
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

#Preview("Logs") {
    NavigationStack { LogsView() }
        .gsTheme(override: .dark)
}
