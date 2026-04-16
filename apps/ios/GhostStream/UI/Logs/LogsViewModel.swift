//
//  LogsViewModel.swift
//  GhostStream
//
//  Polls `PhantomBridge.logs(sinceSeq:)` every 500ms, keeps an
//  in-memory rolling buffer of up to 50 000 entries, and exposes a
//  hierarchical level filter (INFO shows INFO+WARN+ERROR etc.).
//

import Foundation
import Observation
import os.log

/// The set of filter labels shown in the chip row of `LogsView`. The
/// raw string is also what gets passed to `PhantomBridge.setLogLevel`
/// (lower-cased) so the Rust side only emits what the user wants.
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

    /// Rust-side log-level argument (nil = don't reconfigure level).
    var nativeLevel: String? {
        switch self {
        case .all:   return "trace"
        case .trace: return "trace"
        case .debug: return "debug"
        case .info:  return "info"
        // Rust collapses warn/error to info — matches Android semantics.
        case .warn:  return "info"
        case .error: return "info"
        }
    }
}

/// Main-actor observable VM for the Logs screen.
@MainActor
@Observable
final class LogsViewModel {

    // MARK: - Observable state

    /// Rolling buffer of log entries, in emission order (oldest first).
    /// Capped at `maxEntries`.
    private(set) var allLogs: [LogEntry] = []

    /// Active filter chip.
    var filter: LogFilter = .info {
        didSet {
            guard filter != oldValue else { return }
            if let level = filter.nativeLevel {
                PhantomBridge.setLogLevel(level)
            }
        }
    }

    /// `true` while the view wants live polling.
    private(set) var polling = false

    // MARK: - Private

    private var lastSeq: Int64 = -1
    private var pollTask: Task<Void, Never>?
    private let maxEntries = 50_000
    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "LogsVM")

    // MARK: - Derived

    /// `allLogs` reduced to entries at or above the current filter's
    /// priority. Hierarchical: INFO includes WARN + ERROR.
    var visibleLogs: [LogEntry] {
        let min = filter.priority
        if min < 0 { return allLogs }
        return allLogs.filter { LogFilter.priority(of: $0.level) >= min }
    }

    // MARK: - Lifecycle

    init() {
        if let level = filter.nativeLevel {
            PhantomBridge.setLogLevel(level)
        }
    }

    /// Starts the 500ms polling loop. Idempotent.
    func startPolling() {
        guard !polling else { return }
        polling = true
        pollTask = Task { @MainActor [weak self] in
            while let self, self.polling, !Task.isCancelled {
                self.drainNewEntries()
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

    /// Wipes the in-memory buffer. The Rust ring buffer is untouched —
    /// next poll will continue with `lastSeq`.
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

    private func drainNewEntries() {
        let fresh = PhantomBridge.logs(sinceSeq: lastSeq)
        guard !fresh.isEmpty else { return }
        lastSeq = fresh.map(\.seq).max() ?? lastSeq
        allLogs.append(contentsOf: fresh)
        if allLogs.count > maxEntries {
            allLogs.removeFirst(allLogs.count - maxEntries)
        }
    }

    /// Format an entry for file export / clipboard.
    static func format(_ e: LogEntry) -> String {
        let ts = Date(timeIntervalSince1970: e.ts)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return "\(f.string(from: ts)) [\(e.level)] \(e.target): \(e.message)"
    }

    /// Format timestamp for the list row ("HH:MM:SS").
    static func formatTs(_ ts: Double) -> String {
        let d = Date(timeIntervalSince1970: ts)
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
