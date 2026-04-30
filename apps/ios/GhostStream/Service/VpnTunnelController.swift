// VpnTunnelController — NETunnelProviderManager wrapper. Installs the
// VPN configuration under Settings → VPN and starts / stops the Packet
// Tunnel Provider extension.

import Foundation
import Darwin
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
        let expandedDirectCidrs = await directCidrsForTunnelStart(
            preferences: preferences,
            routingMode: effectiveRoutingMode
        )

        let settings = TunnelSettings(
            dnsLeakProtection: preferences.dnsLeakProtection,
            ipv6Killswitch: preferences.ipv6Killswitch,
            autoReconnect: preferences.autoReconnect,
            routingMode: effectiveRoutingMode,
            manualDirectCidrs: expandedDirectCidrs,
            preserveScopedDns: preferences.preserveScopedDns,
            routePolicy: RoutePolicySnapshot(
                mode: effectiveRoutingMode,
                manualDirectCidrs: expandedDirectCidrs,
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

    private func directCidrsForTunnelStart(
        preferences: PreferencesStore,
        routingMode: RoutingMode
    ) async -> [String] {
        guard routingMode != .global else {
            return preferences.manualDirectCidrs
        }

        var cidrs = preferences.manualDirectCidrs
        cidrs.append(contentsOf: RoutingRulesManager.shared.mergedCountryCidrs(
            countryCodes: preferences.directCountries
        ))
        cidrs.append(contentsOf: await Self.resolveDomainCidrs(preferences.customDirectDomains))

        return RoutePolicySnapshot.normalizedCidrs(from: cidrs.joined(separator: "\n")).valid
    }

    private static func resolveDomainCidrs(_ domains: [String]) async -> [String] {
        guard !domains.isEmpty else { return [] }

        return await Task.detached(priority: .utility) {
            var cidrs: [String] = []
            var seen = Set<String>()

            for domain in domains.prefix(50) {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_INET,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: IPPROTO_TCP,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(domain, nil, &hints, &result) == 0 else {
                    continue
                }
                defer { freeaddrinfo(result) }

                var cursor = result
                while let node = cursor {
                    defer { cursor = node.pointee.ai_next }
                    guard let addr = node.pointee.ai_addr else { continue }

                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let status = host.withUnsafeMutableBufferPointer { buffer in
                        getnameinfo(
                            addr,
                            socklen_t(node.pointee.ai_addrlen),
                            buffer.baseAddress,
                            socklen_t(buffer.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                    }
                    guard status == 0 else { continue }

                    let ip = String(cString: host)
                    let cidr = "\(ip)/32"
                    if seen.insert(cidr).inserted {
                        cidrs.append(cidr)
                    }
                }
            }

            return cidrs
        }.value
    }

    /// Returns the current system VPN status for the installed GhostStream
    /// manager. Used by the UI to avoid trusting stale App Group snapshots.
    public func currentStatus() async -> NEVPNStatus {
        do {
            try await loadFromPreferences()
            return manager?.connection.status ?? .invalid
        } catch {
            log.error("reload before status failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
            return .invalid
        }
    }

    /// Stops the tunnel, if any. No-op when no manager is loaded.
    public func stopAndWait() async {
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

    /// Stops the tunnel, if any. Fire-and-forget wrapper for legacy callers.
    public func stop() {
        Task { @MainActor in
            await stopAndWait()
        }
    }

    /// Removes the installed VPN configuration from system preferences.
    public func remove() async throws {
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
    }

}
