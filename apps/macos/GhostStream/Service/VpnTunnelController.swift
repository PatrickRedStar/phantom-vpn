//
//  VpnTunnelController.swift
//  GhostStream (macOS)
//
//  Thin wrapper over `NETunnelProviderManager`. Adapted from
//  apps/ios/GhostStream/Service/VpnTunnelController.swift, with macOS-
//  specific provider bundle id derivation.
//

import Foundation
import NetworkExtension
import PhantomKit
import os.log

public enum VpnTunnelError: LocalizedError {
    case noManager
    case saveFailed(String)
    case reloadFailed(String)
    case startFailed(String)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .noManager:            return "VPN configuration not loaded"
        case .saveFailed(let msg):  return "Failed to save VPN configuration: \(msg)"
        case .reloadFailed(let msg): return "Failed to reload VPN configuration: \(msg)"
        case .startFailed(let msg): return "Failed to start VPN tunnel: \(msg)"
        case .encoding:             return "Failed to encode provider configuration"
        }
    }
}

@MainActor
public final class VpnTunnelController: ObservableObject {

    @Published public private(set) var manager: NETunnelProviderManager?
    @Published public var lastError: String?

    /// macOS system-extension bundle id. Hardcoded against the project.yml
    /// extension bundle id; on iOS this would be derived from the host
    /// bundle id, but on macOS the system extension is a sibling, not a
    /// child.
    private let providerBundleId = "com.ghoststream.vpn.tunnel"

    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "VpnTunnelController")

    public init() {}

    public func loadFromPreferences(expectedProfileId: String? = nil) async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = selectManager(
            from: ghostStreamManagers(in: all),
            expectedProfileId: expectedProfileId
        ) {
            manager = existing
        } else {
            manager = NETunnelProviderManager()
        }
    }

    /// Configure & save a `NETunnelProviderManager` without starting the
    /// tunnel. macOS surfaces the "Allow VPN configuration" permission
    /// dialog the first time `saveToPreferences` succeeds — used by the
    /// onboarding wizard to gate that consent moment.
    public func installOnly(
        profile: VpnProfile,
        preferences: PreferencesStore? = nil
    ) async throws {
        lastError = nil
        let preferences = preferences ?? PreferencesStore.shared

        var providerProfile = profile
        let effectiveRoutingMode = preferences.effectiveRoutingMode(
            profileSplitRouting: profile.splitRouting
        )
        providerProfile.dnsServers = preferences.dnsServers ?? profile.dnsServers
        providerProfile.splitRouting = effectiveRoutingMode.legacySplitRoutingValue
        let routePolicy = UpstreamVpnRouteDetector().snapshot(
            profile: providerProfile,
            preferences: preferences
        )

        let profileData: Data
        let settingsData: Data
        do {
            profileData = try JSONEncoder().encode(providerProfile)
            let settings = TunnelSettings(
                dnsLeakProtection: preferences.dnsLeakProtection,
                ipv6Killswitch: preferences.ipv6Killswitch,
                autoReconnect: preferences.autoReconnect,
                routingMode: effectiveRoutingMode,
                manualDirectCidrs: preferences.manualDirectCidrs,
                preserveScopedDns: preferences.preserveScopedDns,
                routePolicy: routePolicy,
                streams: preferences.streams
            )
            settingsData = try JSONEncoder().encode(settings)
        } catch {
            let wrapped = VpnTunnelError.encoding
            lastError = wrapped.localizedDescription
            throw wrapped
        }

        let managerToSave: NETunnelProviderManager
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            let ghostManagers = ghostStreamManagers(in: all)
            logLoadedManagers(ghostManagers, currentProfileId: profile.id)
            managerToSave = selectManager(from: ghostManagers, expectedProfileId: profile.id)
                ?? NETunnelProviderManager()
        } catch {
            let wrapped = VpnTunnelError.reloadFailed(error.localizedDescription)
            lastError = wrapped.localizedDescription
            throw wrapped
        }

        let proto = NETunnelProviderProtocol()
        proto.serverAddress = profile.serverAddr
        proto.providerBundleIdentifier = providerBundleId
        proto.providerConfiguration = [
            "profile": profileData,
            "settings": settingsData,
        ]

        managerToSave.protocolConfiguration = proto
        managerToSave.localizedDescription = profile.name
        managerToSave.isEnabled = true

        do {
            log.info("saving GhostStream VPN manager profileId=\(profile.id, privacy: .public)")
            try await managerToSave.saveToPreferences()
            manager = try await reloadSavedManager(profileId: profile.id)
        } catch {
            log.error("saveToPreferences failed: \(error.localizedDescription, privacy: .public)")
            let wrapped = error as? VpnTunnelError ?? VpnTunnelError.saveFailed(error.localizedDescription)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    public func installAndStart(profile: VpnProfile, preferences: PreferencesStore) async throws {
        do {
            try await installOnly(profile: profile, preferences: preferences)
            guard let manager else { throw VpnTunnelError.noManager }
            guard providerProfileId(in: manager) == profile.id else {
                let configuredId = providerProfileId(in: manager) ?? "<missing>"
                throw VpnTunnelError.startFailed(
                    "VPN configuration has stale profileId \(configuredId); expected \(profile.id)"
                )
            }
            log.info("starting GhostStream VPN tunnel profileId=\(profile.id, privacy: .public)")
            try manager.connection.startVPNTunnel()
        } catch {
            log.error("startVPNTunnel failed: \(error.localizedDescription, privacy: .public)")
            let wrapped = error as? VpnTunnelError ?? VpnTunnelError.startFailed(error.localizedDescription)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
    }

    public func remove() async throws {
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
    }

    private func reloadSavedManager(profileId: String) async throws -> NETunnelProviderManager {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let ghostManagers = ghostStreamManagers(in: all)
        logLoadedManagers(ghostManagers, currentProfileId: profileId)

        if let current = selectStartManager(from: ghostManagers, profileId: profileId) {
            return current
        }

        let foundIds = ghostManagers
            .map { providerProfileId(in: $0) ?? "<missing>" }
            .joined(separator: ", ")
        throw VpnTunnelError.reloadFailed(
            "expected profileId \(profileId), found [\(foundIds)]"
        )
    }

    private func ghostStreamManagers(
        in managers: [NETunnelProviderManager]
    ) -> [NETunnelProviderManager] {
        managers.filter { candidate in
            (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleId
        }
    }

    private func selectManager(
        from managers: [NETunnelProviderManager],
        expectedProfileId: String?
    ) -> NETunnelProviderManager? {
        if let expectedProfileId {
            if let enabledMatch = managers.first(where: {
                $0.isEnabled && providerProfileId(in: $0) == expectedProfileId
            }) {
                return enabledMatch
            }

            if let match = managers.first(where: {
                providerProfileId(in: $0) == expectedProfileId
            }) {
                return match
            }
        }

        return managers.first(where: \.isEnabled) ?? managers.first
    }

    private func selectStartManager(
        from managers: [NETunnelProviderManager],
        profileId: String
    ) -> NETunnelProviderManager? {
        managers.first { $0.isEnabled && providerProfileId(in: $0) == profileId }
            ?? managers.first { providerProfileId(in: $0) == profileId }
    }

    private func providerProfileId(in manager: NETunnelProviderManager) -> String? {
        guard
            let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration
        else { return nil }

        if let profileId = configuration["profileId"] as? String {
            return profileId
        }

        guard let profileData = configuration["profile"] as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(VpnProfile.self, from: profileData).id
    }

    private func logLoadedManagers(
        _ managers: [NETunnelProviderManager],
        currentProfileId: String
    ) {
        if managers.count > 1 {
            log.warning("found \(managers.count, privacy: .public) GhostStream VPN managers")
        }

        for manager in managers {
            let configuredId = providerProfileId(in: manager) ?? "<missing>"
            if configuredId != currentProfileId {
                log.warning(
                    "GhostStream VPN manager profileId=\(configuredId, privacy: .public) will be overwritten with \(currentProfileId, privacy: .public)"
                )
            }
        }
    }
}
