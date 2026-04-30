// VpnTunnelController — NETunnelProviderManager wrapper. Installs the
// VPN configuration under Settings → VPN and starts / stops the Packet
// Tunnel Provider extension.

import Foundation
import NetworkExtension
import PhantomKit
import os.log

/// Errors raised by `VpnTunnelController`.
public enum VpnTunnelError: LocalizedError {
    case noManager
    case saveFailed(String)
    case startFailed(String)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .noManager:            return "VPN configuration not loaded"
        case .saveFailed(let msg):  return "Failed to save VPN configuration: \(msg)"
        case .startFailed(let msg): return "Failed to start VPN tunnel: \(msg)"
        case .encoding:             return "Failed to encode provider configuration"
        }
    }
}

/// Thin wrapper over `NETunnelProviderManager`. Owns a single installed
/// VPN configuration for the GhostStream Packet Tunnel Provider.
@MainActor
public final class VpnTunnelController: ObservableObject {

    @Published public private(set) var manager: NETunnelProviderManager?
    @Published public var lastError: String?

    private var providerBundleId: String {
        "\(Bundle.main.bundleIdentifier!).PacketTunnelProvider"
    }
    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "VpnTunnelController")

    public init() {}

    private struct LastTunnelParams: Encodable {
        let profileId: String
        let dnsServers: [String]?
        let settings: TunnelSettings

        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
            case dnsServers = "dns_servers"
            case settings
        }
    }

    /// Loads the existing `NETunnelProviderManager` from system
    /// preferences, or creates a fresh one if none is installed.
    public func loadFromPreferences() async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = all.first(where: { candidate in
            (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleId
        }) {
            manager = existing
        } else {
            manager = NETunnelProviderManager()
        }
    }

    /// Installs `profile` into the system VPN configuration and starts the
    /// tunnel. Re-saves and reloads preferences so the system picks up
    /// the new `providerConfiguration`.
    ///
    /// Phase 8: passes only `profileId` plus non-secret runtime settings in
    /// providerConfiguration instead of the full profile JSON blob. The
    /// extension resolves the profile from shared App Group UserDefaults and
    /// hydrates PEM secrets from the shared Keychain access group. This avoids
    /// embedding secrets in the NE configuration dictionary.
    ///
    /// - Throws: `VpnTunnelError.saveFailed` on save error, or
    ///   `VpnTunnelError.startFailed` if the connection won't start.
    public func installAndStart(profile: VpnProfile, preferences: PreferencesStore) async throws {
        lastError = nil
        if manager == nil { try await loadFromPreferences() }
        guard let manager else { throw VpnTunnelError.noManager }

        var providerProfile = profile
        let effectiveRoutingMode = preferences.effectiveRoutingMode(
            profileSplitRouting: profile.splitRouting
        )
        providerProfile.dnsServers = preferences.dnsServers ?? profile.dnsServers
        providerProfile.splitRouting = effectiveRoutingMode.legacySplitRoutingValue

        let settings = TunnelSettings(
            dnsLeakProtection: preferences.dnsLeakProtection,
            ipv6Killswitch: preferences.ipv6Killswitch,
            autoReconnect: preferences.autoReconnect,
            routingMode: effectiveRoutingMode,
            manualDirectCidrs: preferences.manualDirectCidrs,
            preserveScopedDns: preferences.preserveScopedDns,
            routePolicy: RoutePolicySnapshot(
                mode: effectiveRoutingMode,
                manualDirectCidrs: preferences.manualDirectCidrs,
                preserveScopedDns: preferences.preserveScopedDns
            ),
            streams: preferences.streams
        )

        let settingsData: Data
        do {
            settingsData = try JSONEncoder().encode(settings)
            let lastParams = LastTunnelParams(
                profileId: profile.id,
                dnsServers: providerProfile.dnsServers,
                settings: settings
            )
            if let data = try? JSONEncoder().encode(lastParams),
               let json = String(data: data, encoding: .utf8) {
                preferences.saveLastTunnelParams(json)
            }
        } catch {
            lastError = VpnTunnelError.encoding.localizedDescription
            throw VpnTunnelError.encoding
        }

        let proto = NETunnelProviderProtocol()
        proto.serverAddress = providerProfile.serverAddr
        proto.providerBundleIdentifier = providerBundleId

        // Phase 8: pass only the profile id plus non-secret runtime settings;
        // extension loads the full profile + PEM secrets from shared storage.
        var providerConfiguration: [String: Any] = [
            "profileId": profile.id,
            "settings": settingsData,
        ]
        if let dnsServers = providerProfile.dnsServers, !dnsServers.isEmpty {
            providerConfiguration["dnsServers"] = dnsServers
        }
        proto.providerConfiguration = providerConfiguration

        manager.protocolConfiguration = proto
        manager.localizedDescription = profile.name
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            log.error("saveToPreferences failed: \(error.localizedDescription, privacy: .public)")
            lastError = VpnTunnelError.saveFailed(error.localizedDescription).localizedDescription
            throw VpnTunnelError.saveFailed(error.localizedDescription)
        }

        do {
            try manager.connection.startVPNTunnel()
        } catch {
            log.error("startVPNTunnel failed: \(error.localizedDescription, privacy: .public)")
            lastError = VpnTunnelError.startFailed(error.localizedDescription).localizedDescription
            throw VpnTunnelError.startFailed(error.localizedDescription)
        }
    }

    /// Stops the tunnel, if any. No-op when no manager is loaded.
    public func stop() {
        Task { @MainActor in
            do {
                try await loadFromPreferences()
                manager?.connection.stopVPNTunnel()
                lastError = nil
            } catch {
                log.error("reload before stop failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                manager?.connection.stopVPNTunnel()
            }
        }
    }

    /// Removes the installed VPN configuration from system preferences.
    public func remove() async throws {
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
    }

}
