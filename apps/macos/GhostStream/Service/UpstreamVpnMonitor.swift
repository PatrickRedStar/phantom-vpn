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
    private let providerBundleId = "com.ghoststream.vpn.tunnel"
    private var task: Task<Void, Never>?
    private var lastAppliedHash: String?

    private init() {}

    public func start(
        profiles: ProfilesStore,
        preferences: PreferencesStore,
        stateManager: VpnStateManager
    ) {
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

        guard shouldApplyPolicy(for: stateManager.statusFrame.state) else {
            lastAppliedHash = nil
            return
        }
        guard next.routeHash != lastAppliedHash else { return }

        do {
            try await send(next)
            lastAppliedHash = next.routeHash
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func shouldApplyPolicy(for state: ConnState) -> Bool {
        switch state {
        case .connecting, .connected, .reconnecting:
            return true
        case .disconnected, .error:
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
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers
            .filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier == providerBundleId
            }
            .first { isActive($0.connection.status) }
        return manager?.connection as? NETunnelProviderSession
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
