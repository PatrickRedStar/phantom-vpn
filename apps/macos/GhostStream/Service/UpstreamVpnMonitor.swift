//
//  UpstreamVpnMonitor.swift
//  GhostStream (macOS)
//

import Foundation
import NetworkExtension
import Observation
import PhantomKit

public enum UpstreamVpnMonitorError: LocalizedError {
    case noActiveSession
    case providerError(String)

    public var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "GhostStream tunnel session is not active"
        case .providerError(let message):
            return message
        }
    }
}

@MainActor
@Observable
public final class UpstreamVpnMonitor {
    public static let shared = UpstreamVpnMonitor()

    public private(set) var snapshot = RoutePolicySnapshot()
    public private(set) var lastError: String?

    private let detector = UpstreamVpnRouteDetector()
    private var task: Task<Void, Never>?
    private var lastAppliedHash: String?
    /// Гистерезис: hash снапшота с предыдущего poll'а. Применяем policy
    /// только когда hash стабилен два poll'а подряд (~10 с) — одиночный
    /// дребезг таблицы маршрутов (Cisco переустанавливает routes) больше
    /// не дёргает setTunnelNetworkSettings.
    private var pendingHash: String?
    private weak var stateManager: VpnStateManager?

    private init() {}

    public func start(
        profiles: ProfilesStore,
        preferences: PreferencesStore,
        stateManager: VpnStateManager
    ) {
        self.stateManager = stateManager
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll(
                    profiles: profiles,
                    preferences: preferences,
                    stateManager: stateManager
                )
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        lastAppliedHash = nil
        pendingHash = nil
    }

    /// Вызывается из `VpnTunnelController.installOnly` после сохранения
    /// менеджера: снапшот, запечённый в providerConfiguration, применит
    /// сам `startTunnel`. Без seed'а первый poll после connect считал бы
    /// `lastAppliedHash == nil` и слал бы provider'у повторный apply тех
    /// же настроек — лишний reassert-флап сразу после подключения.
    public func seedAppliedHash(_ hash: String) {
        lastAppliedHash = hash
        pendingHash = nil
    }

    public func refresh(
        profiles: ProfilesStore,
        preferences: PreferencesStore,
        stateManager: VpnStateManager
    ) async {
        await poll(profiles: profiles, preferences: preferences, stateManager: stateManager)
    }

    private func poll(
        profiles: ProfilesStore,
        preferences: PreferencesStore,
        stateManager: VpnStateManager
    ) async {
        let activeProfile = profiles.activeProfile
        let input = UpstreamVpnRouteDetector.SnapshotInput(
            mode: preferences.effectiveRoutingMode(profileSplitRouting: activeProfile?.splitRouting),
            manualDirectCidrs: preferences.manualDirectCidrs,
            preserveScopedDns: preferences.preserveScopedDns,
            serverAddr: activeProfile?.serverAddr,
            tunAddr: activeProfile?.tunAddr
        )
        let next = await detector.snapshot(input)
        snapshot = next

        // Применяем только в .connected: apply во время .connecting гнался
        // со стартовым setTunnelNetworkSettings провайдера и рвал handshake
        // (Cisco instant-disconnect, июль 2026). lastAppliedHash при выходе
        // из connected НЕ сбрасываем — его засеивает installOnly перед
        // каждым стартом (seedAppliedHash).
        guard shouldApplyPolicy(for: stateManager.statusFrame.state) else {
            pendingHash = nil
            return
        }
        guard next.routeHash != lastAppliedHash else {
            pendingHash = nil
            return
        }
        // Гистерезис: ждём тот же hash два poll'а подряд.
        guard next.routeHash == pendingHash else {
            pendingHash = next.routeHash
            return
        }

        do {
            try await send(next)
            lastAppliedHash = next.routeHash
            pendingHash = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func shouldApplyPolicy(for state: ConnState) -> Bool {
        switch state {
        case .connected:
            return true
        case .connecting, .reconnecting, .disconnected, .error:
            return false
        }
    }

    private func send(_ snapshot: RoutePolicySnapshot) async throws {
        guard let session = try await activeSession() else {
            throw UpstreamVpnMonitorError.noActiveSession
        }
        let response = try await TunnelIpcBridge(session: session).send(.updateRoutePolicy(snapshot))
        switch response {
        case .ok:
            return
        case .error(let message):
            throw UpstreamVpnMonitorError.providerError(message)
        default:
            throw UpstreamVpnMonitorError.providerError("Unexpected route policy response")
        }
    }

    private func activeSession() async throws -> NETunnelProviderSession? {
        guard let manager = await stateManager?.cachedOrLoadManager(),
              isActive(manager.connection.status)
        else { return nil }
        return manager.connection as? NETunnelProviderSession
    }

    private func isActive(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting:
            return true
        case .disconnecting, .disconnected, .invalid:
            return false
        @unknown default:
            return false
        }
    }
}
