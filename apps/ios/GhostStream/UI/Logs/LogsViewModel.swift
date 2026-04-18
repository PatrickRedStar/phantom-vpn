//
//  LogsViewModel.swift
//  GhostStream
//
//  Polls the PacketTunnelProvider via TunnelIpcBridge every 500ms for
//  LogFrame entries. Keeps an in-memory rolling buffer of up to 50 000
//  entries and exposes a hierarchical level filter.

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
        case "TRACE": return 0
        case "DEBUG": return 1
        case "INFO", "OK": return 2
        case "WARN", "WARNING": return 3
        case "ERROR", "ERR", "CRITICAL": return 4
        default: return 2
        }
    }
}

/// Main-actor observable VM for the Logs screen.
@MainActor
@Observable
final class LogsViewModel {

    // MARK: - Observable state

    /// Rolling buffer of log frames, in emission order (oldest first).
    /// Capped at `maxEntries`.
    private(set) var allLogs: [LogFrame] = []

    /// Active filter chip.
    var filter: LogFilter = .info

    /// `true` while the view wants live polling.
    private(set) var polling = false

    // MARK: - Private

    private var lastTsMs: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var ipc: TunnelIpcBridge?
    private let maxEntries = 50_000
    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "LogsVM")

    // MARK: - Derived

    /// `allLogs` reduced to entries at or above the current filter's
    /// priority. Hierarchical: INFO includes WARN + ERROR.
    var visibleLogs: [LogFrame] {
        let min = filter.priority
        if min < 0 { return allLogs }
        return allLogs.filter { LogFilter.priority(of: $0.level) >= min }
    }

    // MARK: - Lifecycle

    /// Starts the 500ms polling loop. Idempotent.
    func startPolling() {
        guard !polling else { return }
        polling = true
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.setupIpc()
            while self.polling, !Task.isCancelled {
                await self.drainNewEntries()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Stops the polling loop.
    func stopPolling() {
        polling = false
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Actions

    /// Wipes the in-memory buffer.
    func clear() {
        allLogs.removeAll()
    }

    /// Writes the last `range` entries (newest first in file) to a temp
    /// `.txt` file and returns its URL for presentation in a share sheet.
    /// Returns `nil` on I/O failure.
    func shareFileURL(range: Int = 500) -> URL? {
        let tail = allLogs.suffix(range)
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
            if let session = managers.first?.connection as? NETunnelProviderSession {
                ipc = TunnelIpcBridge(session: session)
            }
        } catch {
            log.error("Failed to load VPN manager for IPC: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches new log entries from the extension via IPC.
    private func drainNewEntries() async {
        guard let ipc else { return }
        do {
            let response = try await ipc.send(.subscribeLogs(sinceMs: lastTsMs))
            if case .logs(let frames) = response, !frames.isEmpty {
                lastTsMs = frames.map(\.tsUnixMs).max() ?? lastTsMs
                allLogs.append(contentsOf: frames)
                if allLogs.count > maxEntries {
                    allLogs.removeFirst(allLogs.count - maxEntries)
                }
            }
        } catch {
            // IPC can fail when tunnel isn't running — silently retry next poll
        }
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
        case "WARN", "WARNING":          return "WRN"
        case "INFO", "OK":               return "INF"
        case "DEBUG":                    return "DBG"
        case "TRACE":                    return "TRC"
        default: return String(level.uppercased().prefix(3))
        }
    }
}
