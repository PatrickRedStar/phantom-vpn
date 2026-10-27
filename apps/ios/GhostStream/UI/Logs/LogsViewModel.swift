//
//  LogsViewModel.swift
//  GhostStream
//
//  App-wide journal: while the app runs, pulls LogFrame entries from the
//  PacketTunnelProvider via TunnelIpcBridge once a second when the tunnel
//  is up (whatever tab is open), and imports the tail the extension saves
//  on stop (`ext-tail.jsonl`) when it is down. Keeps a rolling buffer of
//  up to 10 000 entries (as Android), mirrored to logs.jsonl in the App
//  Group so the journal survives app restarts.

import Foundation
import NetworkExtension
import Observation
import PhantomKit
import os.log

/// The set of filter labels shown in the chip row of `LogsView`.
/// Filtering is now purely client-side — the Rust side always emits at
/// its configured level (no more `setLogLevel` IPC).
enum LogFilter: String, CaseIterable, Hashable {
    case all    = "ALL"
    case trace  = "TRACE"
    case debug  = "DEBUG"
    case info   = "INFO"
    case warn   = "WARN"
    case error  = "ERROR"

    /// Filter priority. Higher = more verbose. ALL (-1) passes everything.
    var priority: Int {
        switch self {
        case .all:   return -1
        case .trace: return 0
        case .debug: return 1
        case .info:  return 2
        case .warn:  return 3
        case .error: return 4
        }
    }

    /// Log-level string as emitted by Rust, mapped to a priority.
    static func priority(of level: String) -> Int {
        switch level.uppercased() {
        // The core and the provider send 3-char codes (TRC/DBG/INF/WRN/ERR).
        case "TRACE", "TRC": return 0
        case "DEBUG", "DBG": return 1
        case "INFO", "INF", "OK": return 2
        case "WARN", "WRN", "WARNING": return 3
        case "ERROR", "ERR", "CRITICAL": return 4
        default: return 2
        }
    }
}

/// Main-actor observable VM for the Logs screen.
@MainActor
@Observable
final class LogsViewModel {

    /// One journal for the app: failures happen while the Logs tab is closed.
    static let shared = LogsViewModel()

    // MARK: - Observable state

    /// Rolling buffer of log frames, in emission order (oldest first).
    /// Capped at `maxEntries`.
    private(set) var allLogs: [LogFrame] = []

    /// Active filter chip.
    var filter: LogFilter = .info

    /// Native search field text. Applied client-side by `LogsPresentation`.
    var searchText: String = ""

    /// App-wide VPN state; views reading it re-render on its changes.
    var tunnelState: VpnState { VpnStateManager.shared.state }

    /// Last IPC failure seen while asking the provider for logs.
    private(set) var lastIpcError: String?

    // MARK: - Private

    @ObservationIgnored private var lastTsUs: UInt64 = 0
    @ObservationIgnored private var ipc: TunnelIpcBridge?
    @ObservationIgnored private var collecting = false
    private let maxEntries = 10_000
    private let log = Logger(subsystem: "com.ghoststream.client", category: "LogsVM")
    /// One JSON LogFrame per line; the app is the only writer.
    private let historyURL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: SharedKeys.appGroup)?
        .appendingPathComponent("logs.jsonl")
    /// Last frames the extension saved when it stopped (A8).
    private let tailURL = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: SharedKeys.appGroup)?
        .appendingPathComponent("ext-tail.jsonl")
    @ObservationIgnored private var tailImportedAt: Date?

    private init() {}

    // MARK: - Derived

    /// `allLogs` reduced to entries at or above the current filter's
    /// priority. Hierarchical: INFO includes WARN + ERROR.
    var visibleLogs: [LogFrame] {
        LogsPresentation.visibleLogs(
            allLogs: allLogs,
            filter: filter,
            searchText: searchText
        )
    }

    var hasIpcError: Bool { lastIpcError != nil }

    var isDisconnected: Bool {
        switch tunnelState {
        case .disconnected, .disconnecting:
            return true
        case .connecting, .connected, .reconnecting, .error:
            return false
        }
    }

    var statusLabel: String {
        if hasIpcError { return "IPC ERROR" }
        switch tunnelState {
        case .connected: return "LIVE"
        case .connecting: return "CONNECTING"
        case .reconnecting: return "RECONNECTING"
        case .disconnecting: return "DISCONNECTING"
        case .error: return "VPN ERROR"
        case .disconnected: return "DISCONNECTED"
        }
    }

    var statusMessage: String? {
        if let lastIpcError {
            return "IPC: \(lastIpcError)"
        }

        switch tunnelState {
        case .disconnected, .disconnecting:
            return AppStrings.localized("native.logs.status.offline")
        case .error(let message):
            return message
        case .connecting, .connected, .reconnecting:
            return nil
        }
    }

    // MARK: - Lifecycle

    /// Runs for the app's lifetime (root `.task`): saved journal first,
    /// then once a second — new lines over IPC while the tunnel is up,
    /// the extension's saved tail while it is down.
    func collect() async {
        guard !collecting else { return }
        collecting = true
        defer { collecting = false }
        await loadHistory()
        while !Task.isCancelled {
            if shouldAttemptIpc {
                await drainNewEntries()
            } else {
                ipc = nil
                if lastIpcError != nil { lastIpcError = nil }
                importExtensionTail()
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Actions

    /// Wipes the buffer and the saved history. The IPC cursor stays, so
    /// cleared lines don't come back from the extension's ring.
    func clear() {
        allLogs.removeAll()
        if let historyURL { try? FileManager.default.removeItem(at: historyURL) }
    }

    /// Writes the last `range` entries shown (filter + search applied),
    /// oldest first, to a temp `.txt` file for the share sheet. Returns
    /// `nil` on I/O failure.
    func shareFileURL(range: Int = 500) -> URL? {
        let tail = visibleLogs.prefix(range).reversed()
        let lines = tail.map { Self.format($0) }
        let body = lines.joined(separator: "\n")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghoststream-logs-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log.error("Failed to write logs: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Private

    /// Loads the NETunnelProviderManager and creates a TunnelIpcBridge
    /// to communicate with the PacketTunnelProvider extension.
    private func setupIpc() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            guard let manager = selectTunnelManager(from: managers) else {
                ipc = nil
                recordIpcError("VPN configuration is not installed")
                return
            }
            guard let session = manager.connection as? NETunnelProviderSession else {
                ipc = nil
                recordIpcError("VPN provider session is unavailable")
                return
            }
            ipc = TunnelIpcBridge(session: session)
            lastIpcError = nil
        } catch {
            ipc = nil
            recordIpcError("Failed to load VPN manager: \(error.localizedDescription)")
        }
    }

    /// Fetches new log entries from the extension via IPC.
    private func drainNewEntries() async {
        if ipc == nil {
            await setupIpc()
        }

        guard let bridge = ipc else { return }
        do {
            let response = try await bridge.send(.subscribeLogs(sinceUs: lastTsUs))
            if case .error(let message) = response {
                recordIpcError(message)
                return
            }

            guard case .logs(let frames) = response else {
                recordIpcError("Unexpected IPC response")
                return
            }

            if lastIpcError != nil { lastIpcError = nil }
            append(frames)
        } catch {
            ipc = nil
            recordIpcError(error.localizedDescription)
        }
    }

    /// Lines the stopped extension left behind; only those newer than the
    /// cursor, so what IPC already delivered is not added twice.
    private func importExtensionTail() {
        guard let tailURL,
              let modified = (try? FileManager.default.attributesOfItem(atPath: tailURL.path))?[.modificationDate] as? Date,
              modified != tailImportedAt
        else { return }
        tailImportedAt = modified
        append(Self.readFrames(tailURL).filter { $0.timestampUs > lastTsUs })
    }

    private func append(_ frames: [LogFrame]) {
        guard !frames.isEmpty else { return }
        lastTsUs = max(lastTsUs, frames.map(\.timestampUs).max() ?? 0)
        allLogs.append(contentsOf: frames)
        // Trim in 1k chunks: one O(n) shift per ~1k lines, not per poll.
        if allLogs.count > maxEntries {
            allLogs.removeFirst(allLogs.count - maxEntries + maxEntries / 10)
            writeHistory(allLogs, append: false)
        } else {
            writeHistory(frames, append: true)
        }
    }

    // MARK: - History file

    /// Off the main thread: up to 10k JSON lines.
    private func loadHistory() async {
        guard let historyURL else { return }
        let frames = await Task.detached(priority: .utility) {
            Self.readFrames(historyURL)
        }.value
        allLogs = Array(frames.suffix(maxEntries))
        // The extension's ring still holds these — don't fetch them twice.
        lastTsUs = allLogs.map(\.timestampUs).max() ?? 0
    }

    /// JSON Lines of `LogFrame`; unreadable lines are skipped.
    nonisolated static func readFrames(_ url: URL) -> [LogFrame] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(LogFrame.self, from: Data($0))
        }
    }

    private func writeHistory(_ frames: [LogFrame], append: Bool) {
        guard let historyURL else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for frame in frames {
            guard let line = try? encoder.encode(frame) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        if append, let handle = try? FileHandle(forWritingTo: historyURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: historyURL, options: .atomic)
        }
    }

    private var shouldAttemptIpc: Bool {
        switch tunnelState {
        case .connected, .connecting, .reconnecting:
            return true
        case .disconnected, .disconnecting, .error:
            return false
        }
    }

    private func selectTunnelManager(from managers: [NETunnelProviderManager]) -> NETunnelProviderManager? {
        // MIG-R4-N11: extension bundle id moved from `.PacketTunnelProvider`
        // to `.tunnel` for parity with macOS. Match both legacy and
        // new suffixes during the fallback path so installs that still
        // have a stale NETunnelProviderManager pointing at the old
        // suffix can still surface their logs while the new manager
        // takes over.
        let expectedProviderId = Bundle.main.bundleIdentifier.map {
            "\($0).tunnel"
        }
        let matches = managers.filter { manager in
            guard let providerId = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier
            else { return false }

            if let expectedProviderId {
                return providerId == expectedProviderId
            }
            return providerId.hasSuffix(".tunnel")
                || providerId.hasSuffix(".PacketTunnelProvider")
        }

        return matches.first { $0.connection.status != .disconnected } ?? matches.first
    }

    private func recordIpcError(_ message: String) {
        if lastIpcError != message {
            log.error("Log IPC failed: \(message, privacy: .public)")
        }
        lastIpcError = message
    }

    /// Format an entry for file export / clipboard.
    static func format(_ e: LogFrame) -> String {
        let ts = Date(timeIntervalSince1970: Double(e.tsUnixMs) / 1000.0)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "\(f.string(from: ts)) [\(e.level)] \(e.msg)"
    }

    /// Format timestamp for the list row ("HH:MM:SS").
    static func formatTs(_ tsMs: UInt64) -> String {
        let d = Date(timeIntervalSince1970: Double(tsMs) / 1000.0)
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    /// 3-char level badge for the list row ("INF" / "WRN" / "ERR" / ...).
    static func levelBadge(_ level: String) -> String {
        switch level.uppercased() {
        case "ERROR", "ERR", "CRITICAL": return "ERR"
        case "WARN", "WARNING", "WRN":   return "WRN"
        case "INFO", "OK", "INF":        return "INF"
        case "DEBUG", "DBG":             return "DBG"
        case "TRACE", "TRC":             return "TRC"
        default: return String(level.uppercased().prefix(3))
        }
    }
}
