//
//  TailView.swift
//  GhostStream (macOS)
//
//  TAIL tab — pixel-matched to section 03 of the design HTML.
//
//  Layout:
//   1. detail-head: lblmono "live tail" faint + 38pt hero "tail." with
//      em italic signal serif accent + "● 247 lines · streaming" right.
//   2. toolbar: tool-pills [all|info|warn|error|debug] with active state
//      (signal text + signal.opacity(0.06) bg + signal-dim border) and
//      filter input on the right with ⌘F + ⌘L kbd hints.
//   3. table: 86pt ts column / 60pt level column / msg fills the rest.
//      Row colours per level (ok=signal, info=textDim, warn=warn,
//      err=danger, dbg=debug).
//

import AppKit
import NetworkExtension
import PhantomKit
import PhantomUI
import SwiftUI
import UniformTypeIdentifiers

public struct TailView: View {

    @Environment(\.gsColors) private var C
    @Environment(VpnStateManager.self) private var stateMgr

    @State private var activeFilter: LevelFilter = .all
    @State private var searchText: String = ""
    @State private var regexSearch: Bool = false
    @State private var logs: [LogFrame] = []
    @State private var lastLogTsMs: UInt64 = 0
    @State private var ipcBridge: TunnelIpcBridge?
    @State private var pollTask: Task<Void, Never>?
    @State private var pollErrorMessage: String?
    @State private var actionStatus: TailStatus?
    private let providerBundleId = "com.ghoststream.vpn.tunnel"

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailHead
            toolbar
            tailStatusStrip
            tailTable
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
        .onAppear { startPollingLogs() }
        .onDisappear { stopPollingLogs() }
    }

    // MARK: - 1. detail-head

    @ViewBuilder
    private var detailHead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIVE TAIL")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.20 * 11)
                    .foregroundStyle(C.textFaint)
                HStack(spacing: 0) {
                    Text("tail")
                        .font(.custom("InstrumentSerif-Italic", size: 38))
                        .foregroundStyle(C.signal)
                    Text(".")
                        .font(.custom("SpaceGrotesk-Bold", size: 38))
                        .foregroundStyle(C.textDim)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                PulseDot(color: C.signal, size: 8, pulse: true)
                Text("\(filteredLogs.count) LINES · \(stateMgr.statusFrame.state == .connected ? "STREAMING" : "STANDBY")")
                    .font(.custom("DepartureMono-Regular", size: 10.5))
                    .tracking(0.16 * 10.5)
                    .foregroundStyle(C.textDim)
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            DashedHairline()
        }
    }

    // MARK: - 2. toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 0) {
            // Pill group — joined borders
            HStack(spacing: 0) {
                ForEach(Array(LevelFilter.allCases.enumerated()), id: \.element) { idx, filter in
                    let isActive = activeFilter == filter
                    let isLast = idx == LevelFilter.allCases.count - 1
                    Button { activeFilter = filter } label: {
                        Text(filter.label)
                            .font(.custom("DepartureMono-Regular", size: 10.5))
                            .tracking(0.16 * 10.5)
                            .foregroundStyle(isActive ? C.signal : C.textDim)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isActive ? C.signal.opacity(0.06) : C.bgElev)
                            .overlay(alignment: .top) {
                                Rectangle()
                                    .fill(isActive ? C.signalDim : C.hairBold)
                                    .frame(height: 1)
                            }
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(isActive ? C.signalDim : C.hairBold)
                                    .frame(height: 1)
                            }
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(isActive ? C.signalDim : C.hairBold)
                                    .frame(width: 1)
                            }
                            .overlay(alignment: .trailing) {
                                if isLast {
                                    Rectangle()
                                        .fill(isActive ? C.signalDim : C.hairBold)
                                        .frame(width: 1)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            // Filter input
            HStack(spacing: 8) {
                TextField(regexSearch ? "filter · regex" : "filter · contains", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.custom("JetBrainsMono-Regular", size: 11.5))
                    .foregroundStyle(C.bone)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 280)
                    .overlay(
                        Rectangle().stroke(C.hairBold, lineWidth: 1)
                    )
                Button {
                    regexSearch.toggle()
                } label: {
                    Text("REGEX")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .tracking(0.16 * 10)
                        .foregroundStyle(regexSearch ? C.signal : C.textDim)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(regexSearch ? C.signal.opacity(0.06) : C.bgElev)
                        .overlay(Rectangle().stroke(regexSearch ? C.signalDim : C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    copyVisibleLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textDim)
                        .frame(width: 28, height: 28)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    exportVisibleLogs()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 12))
                        .foregroundStyle(C.textDim)
                        .frame(width: 28, height: 28)
                        .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
                }
                .buttonStyle(.plain)
                KeyboardShortcutHint("⌘F")
                KeyboardShortcutHint("⌘L")
            }
        }
    }

    @ViewBuilder
    private var tailStatusStrip: some View {
        if let status = visibleTailStatus {
            HStack(spacing: 8) {
                Image(systemName: status.iconName)
                    .font(.system(size: 12, weight: .semibold))
                Text(status.message)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tailStatusColor(status.tone))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tailStatusColor(status.tone).opacity(0.06))
            .overlay(
                Rectangle().stroke(tailStatusColor(status.tone).opacity(0.35), lineWidth: 1)
            )
        }
    }

    // MARK: - 3. tail table

    @ViewBuilder
    private var tailTable: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if filteredLogs.isEmpty {
                        Text(String(localized: "logs.empty"))
                            .font(.custom("JetBrainsMono-Regular", size: 12))
                            .foregroundStyle(C.textFaint)
                            .padding(40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(filteredLogs) { row in
                            tailRow(row)
                            Rectangle().fill(C.hair).frame(height: 1)
                        }
                        Color.clear.frame(height: 1).id("tail-bottom")
                    }
                }
            }
            .onChange(of: logs.count) { _, _ in
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo("tail-bottom", anchor: .bottom)
                }
            }
            .onChange(of: filteredLogs.count) { _, _ in
                proxy.scrollTo("tail-bottom", anchor: .bottom)
            }
        }
        .background(C.bgElev2)
        .overlay(Rectangle().stroke(C.hair, lineWidth: 1))
    }

    @ViewBuilder
    private func tailRow(_ row: LogFrame) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(formatTs(row.tsUnixMs))
                .font(.custom("JetBrainsMono-Regular", size: 10.5))
                .foregroundStyle(C.textFaint)
                .frame(width: 86, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Text(row.level.lowercased())
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.14 * 9.5)
                .foregroundStyle(levelColor(row.level))
                .frame(width: 60, alignment: .leading)
                .padding(.vertical, 8)
            Text(row.msg)
                .font(.custom("JetBrainsMono-Regular", size: 11))
                .foregroundStyle(C.bone)
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .textSelection(.enabled)
        }
    }

    // MARK: - Helpers

    private var filteredLogs: [LogFrame] {
        let regex = activeSearchRegex
        return logs.filter { row in
            let levelOk = activeFilter == .all || row.level.lowercased() == activeFilter.matchKey
            let textOk = matchesSearch(row, regex: regex)
            return levelOk && textOk
        }
    }

    private var activeSearchRegex: NSRegularExpression? {
        guard regexSearch, !searchText.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: searchText, options: [.caseInsensitive])
    }

    private var regexSearchError: String? {
        guard regexSearch, !searchText.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: searchText, options: [.caseInsensitive])
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var visibleTailStatus: TailStatus? {
        if let regexSearchError {
            return TailStatus(message: "Invalid regex: \(regexSearchError)", tone: .danger)
        }
        if let actionStatus, actionStatus.tone != .info {
            return actionStatus
        }
        if let pollErrorMessage {
            return TailStatus(message: pollErrorMessage, tone: .danger)
        }
        return actionStatus
    }

    private func matchesSearch(_ row: LogFrame, regex: NSRegularExpression?) -> Bool {
        guard !searchText.isEmpty else { return true }
        let haystack = "\(row.level) \(row.msg)"
        guard regexSearch else {
            return haystack.localizedCaseInsensitiveContains(searchText)
        }
        guard let regex else { return true }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    private func startPollingLogs() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await pollLogsOnce()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopPollingLogs() {
        pollTask?.cancel()
        pollTask = nil
    }

    @MainActor
    private func pollLogsOnce() async {
        guard shouldPollLogs else {
            pollErrorMessage = nil
            ipcBridge = nil
            return
        }

        if ipcBridge == nil {
            do {
                ipcBridge = try await makeIpcBridge()
            } catch {
                pollErrorMessage = "Log stream setup failed: \(error.localizedDescription)"
                return
            }
        }
        guard let bridge = ipcBridge else {
            pollErrorMessage = "Log stream unavailable: tunnel IPC session not found"
            return
        }

        do {
            let response = try await bridge.send(.subscribeLogs(sinceMs: lastLogTsMs))
            guard case .logs(let frames) = response else {
                pollErrorMessage = "Log stream returned an unexpected IPC response"
                return
            }
            pollErrorMessage = nil
            guard !frames.isEmpty else { return }
            lastLogTsMs = frames.map(\.tsUnixMs).max() ?? lastLogTsMs
            logs.append(contentsOf: frames)
            trimLogs()
        } catch {
            ipcBridge = nil
            pollErrorMessage = "Log polling failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func makeIpcBridge() async throws -> TunnelIpcBridge? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = selectGhostStreamManager(from: managers)
        guard let session = manager?.connection as? NETunnelProviderSession else {
            return nil
        }
        return TunnelIpcBridge(session: session)
    }

    private var shouldPollLogs: Bool {
        switch stateMgr.statusFrame.state {
        case .connecting, .reconnecting, .connected, .error:
            return true
        case .disconnected:
            return false
        }
    }

    private func selectGhostStreamManager(
        from managers: [NETunnelProviderManager]
    ) -> NETunnelProviderManager? {
        let ghostManagers = managers.filter { candidate in
            (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleId
        }

        return ghostManagers.first { isActiveNetworkExtensionStatus($0.connection.status) }
            ?? ghostManagers.first(where: \.isEnabled)
            ?? ghostManagers.first
    }

    private func isActiveNetworkExtensionStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting:
            return true
        case .disconnected, .invalid:
            return false
        @unknown default:
            return false
        }
    }

    private func trimLogs() {
        let maxEntries = 1000
        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }
    }

    private func copyVisibleLogs() {
        let output = renderVisibleLogs()
        guard !output.isEmpty else {
            actionStatus = TailStatus(message: "No visible log lines to copy", tone: .warning)
            return
        }

        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(output, forType: .string) else {
            actionStatus = TailStatus(message: "Copy failed: pasteboard rejected the log text", tone: .danger)
            return
        }
        actionStatus = TailStatus(message: "Copied \(filteredLogs.count) visible log lines", tone: .info)
    }

    private func exportVisibleLogs() {
        let output = renderVisibleLogs()
        guard !output.isEmpty else {
            actionStatus = TailStatus(message: "No visible log lines to export", tone: .warning)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ghoststream-logs-\(Int(Date().timeIntervalSince1970)).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try output.write(to: url, atomically: true, encoding: .utf8)
            actionStatus = TailStatus(message: "Exported \(filteredLogs.count) visible log lines", tone: .info)
        } catch {
            actionStatus = TailStatus(message: "Export failed: \(error.localizedDescription)", tone: .danger)
        }
    }

    private func renderVisibleLogs() -> String {
        filteredLogs.map(formatLogLine).joined(separator: "\n")
    }

    private func formatLogLine(_ row: LogFrame) -> String {
        "\(formatTs(row.tsUnixMs)) [\(row.level)] \(row.msg)"
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error", "err":          return C.danger
        case "warn", "warning":       return C.warn
        case "info":                  return C.textDim
        case "ok", "success":         return C.signal
        case "debug", "dbg":          return C.blueDebug
        default:                      return C.textDim
        }
    }

    private func tailStatusColor(_ tone: TailStatusTone) -> Color {
        switch tone {
        case .info:    return C.signal
        case .warning: return C.warn
        case .danger:  return C.danger
        }
    }

    private func formatTs(_ tsMs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(tsMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter.string(from: date)
    }
}

private struct TailStatus {
    let message: String
    let tone: TailStatusTone

    var iconName: String {
        switch tone {
        case .info:    return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .danger:  return "xmark.octagon"
        }
    }
}

private enum TailStatusTone: Equatable {
    case info
    case warning
    case danger
}

private enum LevelFilter: String, CaseIterable {
    case all, info, warn, error, debug

    var label: String {
        switch self {
        case .all:   return "all"
        case .info:  return "info"
        case .warn:  return "warn"
        case .error: return "error"
        case .debug: return "debug"
        }
    }

    var matchKey: String {
        switch self {
        case .all:   return "*"
        case .info:  return "info"
        case .warn:  return "warn"
        case .error: return "error"
        case .debug: return "debug"
        }
    }
}
