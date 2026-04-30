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

    /// Last VPN state observed from the shared state bridge.
    private(set) var tunnelState: VpnState = VpnStateManager.shared.state

    /// Last IPC failure seen while asking the provider for logs.
    private(set) var lastIpcError: String?

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

    var hasIpcError: Bool { lastIpcError != nil }

    var isDisconnected: Bool {
        switch tunnelState {
        case .disconnected, .disconnecting:
            return true
        case .connecting, .connected, .error:
            return false
        }
    }

    var statusLabel: String {
        if hasIpcError { return "IPC ERROR" }
        switch tunnelState {
        case .connected: return "LIVE"
        case .connecting: return "CONNECTING"
        case .disconnecting: return "DISCONNECTING"
        case .error: return "VPN ERROR"
        case .disconnected: return "DISCONNECTED"
        }
    }

    var statusMessage: String? {
        if let lastIpcError {
            return "IPC error: \(lastIpcError)"
        }

        switch tunnelState {
        case .disconnected:
            return "VPN disconnected. Live log IPC is unavailable."
        case .disconnecting:
            return "VPN disconnecting. Live log IPC may be unavailable."
        case .error(let message):
            return "VPN error: \(message)"
        case .connecting, .connected:
            return nil
        }
    }

    // MARK: - Lifecycle

    /// Starts the 500ms polling loop. Idempotent.
    func startPolling() {
        guard !polling else { return }
        polling = true
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshTunnelState()
            if self.shouldAttemptIpc {
                await self.setupIpc()
            }
            while self.polling, !Task.isCancelled {
                self.refreshTunnelState()
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
        guard shouldAttemptIpc else {
            ipc = nil
            lastIpcError = nil
            return
        }

        if ipc == nil {
            await setupIpc()
        }

        guard let bridge = ipc else { return }
        do {
            let response = try await bridge.send(.subscribeLogs(sinceMs: lastTsMs))
            if case .error(let message) = response {
                recordIpcError(message)
                return
            }

            guard case .logs(let frames) = response else {
                recordIpcError("Unexpected IPC response")
                return
            }

            lastIpcError = nil
            if !frames.isEmpty {
                lastTsMs = frames.map(\.tsUnixMs).max() ?? lastTsMs
                allLogs.append(contentsOf: frames)
                if allLogs.count > maxEntries {
                    allLogs.removeFirst(allLogs.count - maxEntries)
                }
            }
        } catch {
            ipc = nil
            recordIpcError(error.localizedDescription)
        }
    }

    private var shouldAttemptIpc: Bool {
        switch tunnelState {
        case .connected, .connecting:
            return true
        case .disconnected, .disconnecting, .error:
            return false
        }
    }

    private func refreshTunnelState() {
        tunnelState = VpnStateManager.shared.state
    }

    private func selectTunnelManager(from managers: [NETunnelProviderManager]) -> NETunnelProviderManager? {
        let expectedProviderId = Bundle.main.bundleIdentifier.map {
            "\($0).PacketTunnelProvider"
        }
        let matches = managers.filter { manager in
            guard let providerId = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier
            else { return false }

            if let expectedProviderId {
                return providerId == expectedProviderId
            }
            return providerId.hasSuffix(".PacketTunnelProvider")
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
        case "WARN", "WARNING":          return "WRN"
        case "INFO", "OK":               return "INF"
        case "DEBUG":                    return "DBG"
        case "TRACE":                    return "TRC"
        default: return String(level.uppercased().prefix(3))
        }
    }
}
