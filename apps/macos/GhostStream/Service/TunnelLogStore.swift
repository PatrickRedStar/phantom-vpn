//
//  TunnelLogStore.swift
//  GhostStream (macOS)
//
//  Shared live-log collector for the embedded and detached LOGS views.
//

import Foundation
import NetworkExtension
import Observation
import PhantomKit

@MainActor
@Observable
public final class TunnelLogStore {

    public static let shared = TunnelLogStore()

    public private(set) var logs: [LogFrame] = []
    public private(set) var polling: Bool = false
    public private(set) var lastErrorMessage: String?

    private let maxEntries = 50_000
    private var lastLogTsMs: UInt64 = 0
    private var ipcBridge: TunnelIpcBridge?
    private var pollTask: Task<Void, Never>?
    private weak var stateManager: VpnStateManager?

    private init() {}

    public func start(stateManager: VpnStateManager) {
        self.stateManager = stateManager
        guard pollTask == nil else { return }

        polling = true
        pollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollLogsOnce()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            self.polling = false
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        polling = false
        ipcBridge = nil
    }

    public func clear() {
        lastLogTsMs = logs.map(\.tsUnixMs).max() ?? lastLogTsMs
        logs.removeAll()
        lastErrorMessage = nil
    }

    public static func normalizedLevel(_ level: String) -> String {
        switch level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inf", "info":
            return "info"
        case "wrn", "warn", "warning":
            return "warn"
        case "err", "error":
            return "error"
        case "dbg", "debug", "trc", "trace":
            return "debug"
        case "ok", "success":
            return "ok"
        default:
            return "info"
        }
    }

    private func pollLogsOnce() async {
        guard shouldPollLogs else {
            ipcBridge = nil
            lastErrorMessage = nil
            return
        }

        if ipcBridge == nil {
            do {
                ipcBridge = try await makeIpcBridge()
            } catch {
                lastErrorMessage = "Log stream setup failed: \(error.localizedDescription)"
                return
            }
        }

        guard let bridge = ipcBridge else {
            lastErrorMessage = "Log stream unavailable: tunnel IPC session not found"
            return
        }

        do {
            let response = try await bridge.send(.subscribeLogs(sinceMs: lastLogTsMs))
            if case .error(let message) = response {
                lastErrorMessage = message
                return
            }

            guard case .logs(let frames) = response else {
                lastErrorMessage = "Log stream returned an unexpected IPC response"
                return
            }

            lastErrorMessage = nil
            guard !frames.isEmpty else { return }

            lastLogTsMs = frames.map(\.tsUnixMs).max() ?? lastLogTsMs
            logs.append(contentsOf: frames)
            trimLogs()
        } catch {
            ipcBridge = nil
            lastErrorMessage = "Log polling failed: \(error.localizedDescription)"
        }
    }

    private var shouldPollLogs: Bool {
        guard let stateManager else { return false }
        switch stateManager.statusFrame.state {
        case .connecting, .reconnecting, .connected, .error:
            return true
        case .disconnected:
            return false
        }
    }

    private func makeIpcBridge() async throws -> TunnelIpcBridge? {
        guard let manager = await stateManager?.cachedOrLoadManager() else {
            return nil
        }
        guard let session = manager.connection as? NETunnelProviderSession else {
            return nil
        }
        return TunnelIpcBridge(session: session)
    }

    private func trimLogs() {
        if logs.count > maxEntries {
            logs.removeFirst(logs.count - maxEntries)
        }
    }
}
