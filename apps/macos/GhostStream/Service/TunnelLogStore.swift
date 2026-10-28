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
    /// Монотонный счётчик изменений буфера. UI должен наблюдать ЕГО, а не
    /// `logs.count`: после насыщения `maxEntries` trim возвращает count к
    /// одному и тому же значению, `onChange(of: count)` перестаёт
    /// срабатывать и tail «замерзает» (root cause бага «виснет вкладка
    /// логов», июль 2026).
    public private(set) var revision: Int = 0

    /// 10k = размер ring-буфера провайдера (`maxRecentLogFrames`). Прежний
    /// cap 50k держал на main thread массив, который каждый poll
    /// фильтровался и диффился целиком.
    private let maxEntries = 10_000
    private var lastLogTsUs: UInt64 = 0
    private var ipcBridge: TunnelIpcBridge?
    private var pollTask: Task<Void, Never>?
    private weak var stateManager: VpnStateManager?

    private init() {}

    public func start(stateManager: VpnStateManager) {
        #if DEBUG
        if DebugDemo.isActive {
            if logs.isEmpty { logs = DebugDemo.logs; revision += 1 }
            return
        }
        #endif
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
        lastLogTsUs = logs.map(\.timestampUs).max() ?? lastLogTsUs
        logs.removeAll()
        lastErrorMessage = nil
        revision += 1
    }

    public static func normalizedLevel(_ level: String) -> String {
        // Каноничная таблица уровней живёт в LogFrameFilter (PhantomKit,
        // под тестами) — раньше здесь был рукописный дубль.
        LogFrameFilter.normalizedLevel(level).rawValue
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
            let response = try await bridge.send(.subscribeLogs(sinceUs: lastLogTsUs))
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

            lastLogTsUs = frames.map(\.timestampUs).max() ?? lastLogTsUs
            logs.append(contentsOf: frames)
            trimLogs()
            revision += 1
            // Host-side зеркало runtime.log: extension пишет в root-контейнер,
            // невидимый пользователю — см. HostLogMirror.
            HostLogMirror.shared.append(frames)
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
