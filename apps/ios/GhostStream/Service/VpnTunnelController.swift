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
    case noActiveSession
    case saveFailed(String)
    case startFailed(String)
    case encoding
    case routePolicyUpdateFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noManager:            return "VPN configuration not loaded"
        case .noActiveSession:      return "VPN tunnel session is not active"
        case .saveFailed(let msg):  return "Failed to save VPN configuration: \(msg)"
        case .startFailed(let msg): return "Failed to start VPN tunnel: \(msg)"
        case .encoding:             return "Failed to encode provider configuration"
        case .routePolicyUpdateFailed(let msg):
            return "Failed to update VPN route policy: \(msg)"
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

    private struct DirectRouteRules: Sendable {
        let ipv4Cidrs: [String]
        let ipv6Cidrs: [String]
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
        let routeRules = try await directRulesForTunnelStart(
            preferences: preferences,
            routingMode: effectiveRoutingMode
        )

        let settings = TunnelSettings(
            dnsLeakProtection: preferences.dnsLeakProtection,
            ipv6Killswitch: preferences.ipv6Killswitch,
            autoReconnect: preferences.autoReconnect,
            routingMode: effectiveRoutingMode,
            manualDirectCidrs: routeRules.ipv4Cidrs,
            manualDirectIpv6Cidrs: routeRules.ipv6Cidrs,
            preserveScopedDns: preferences.preserveScopedDns,
            routePolicy: RoutePolicySnapshot(
                mode: effectiveRoutingMode,
                manualDirectCidrs: routeRules.ipv4Cidrs,
                manualDirectIpv6Cidrs: routeRules.ipv6Cidrs,
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

    public func applyRoutePolicy(profile: VpnProfile, preferences: PreferencesStore) async throws {
        lastError = nil
        if manager == nil { try await loadFromPreferences() }
        guard let manager else { throw VpnTunnelError.noManager }

        var providerProfile = profile
        let effectiveRoutingMode = preferences.effectiveRoutingMode(
            profileSplitRouting: profile.splitRouting
        )
        providerProfile.dnsServers = preferences.dnsServers ?? profile.dnsServers
        providerProfile.splitRouting = effectiveRoutingMode.legacySplitRoutingValue

        let routeRules = try await directRulesForTunnelStart(
            preferences: preferences,
            routingMode: effectiveRoutingMode
        )
        let snapshot = RoutePolicySnapshot(
            mode: effectiveRoutingMode,
            manualDirectCidrs: routeRules.ipv4Cidrs,
            manualDirectIpv6Cidrs: routeRules.ipv6Cidrs,
            preserveScopedDns: preferences.preserveScopedDns
        )
        let settings = TunnelSettings(
            dnsLeakProtection: preferences.dnsLeakProtection,
            ipv6Killswitch: preferences.ipv6Killswitch,
            autoReconnect: preferences.autoReconnect,
            routingMode: effectiveRoutingMode,
            manualDirectCidrs: routeRules.ipv4Cidrs,
            manualDirectIpv6Cidrs: routeRules.ipv6Cidrs,
            preserveScopedDns: preferences.preserveScopedDns,
            routePolicy: snapshot,
            streams: preferences.streams
        )

        guard let settingsData = try? JSONEncoder().encode(settings) else {
            lastError = VpnTunnelError.encoding.localizedDescription
            throw VpnTunnelError.encoding
        }
        let lastParams = LastTunnelParams(
            profileId: profile.id,
            dnsServers: providerProfile.dnsServers,
            settings: settings
        )
        if let data = try? JSONEncoder().encode(lastParams),
           let json = String(data: data, encoding: .utf8) {
            preferences.saveLastTunnelParams(json)
        }

        let status = manager.connection.status
        if status == .connected || status == .connecting || status == .reasserting {
            guard let session = manager.connection as? NETunnelProviderSession else {
                throw VpnTunnelError.noActiveSession
            }
            let response = try await TunnelIpcBridge(session: session).send(.updateRoutePolicy(snapshot))
            switch response {
            case .ok:
                break
            case .error(let message):
                throw VpnTunnelError.routePolicyUpdateFailed(message)
            default:
                throw VpnTunnelError.routePolicyUpdateFailed("Unexpected provider response")
            }
        }

        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            var providerConfiguration = proto.providerConfiguration ?? [:]
            providerConfiguration["profileId"] = profile.id
            providerConfiguration["settings"] = settingsData
            if let dnsServers = providerProfile.dnsServers, !dnsServers.isEmpty {
                providerConfiguration["dnsServers"] = dnsServers
            } else {
                providerConfiguration.removeValue(forKey: "dnsServers")
            }
            proto.providerConfiguration = providerConfiguration
            proto.serverAddress = providerProfile.serverAddr
            proto.providerBundleIdentifier = providerBundleId
            manager.protocolConfiguration = proto
            manager.localizedDescription = profile.name
            manager.isEnabled = true

            do {
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            } catch {
                log.error("route policy saveToPreferences failed: \(error.localizedDescription, privacy: .public)")
                lastError = VpnTunnelError.saveFailed(error.localizedDescription).localizedDescription
                throw VpnTunnelError.saveFailed(error.localizedDescription)
            }
        }
    }

    private func directRulesForTunnelStart(
        preferences: PreferencesStore,
        routingMode: RoutingMode
    ) async throws -> DirectRouteRules {
        var ipv4Cidrs = preferences.manualDirectCidrs
        var ipv6Cidrs = preferences.manualDirectIpv6Cidrs

        guard routingMode != .global else {
            return DirectRouteRules(
                ipv4Cidrs: RoutePolicySnapshot.normalizedCidrs(
                    from: ipv4Cidrs.joined(separator: "\n")
                ).valid,
                ipv6Cidrs: RoutePolicySnapshot.normalizedIPv6Cidrs(
                    from: ipv6Cidrs.joined(separator: "\n")
                ).valid
            )
        }

        try await RoutingRulesManager.shared.ensureCountryRules(countryCodes: preferences.directCountries)
        let countryRules = RoutingRulesManager.shared.mergedCountryRules(
            countryCodes: preferences.directCountries
        )
        ipv4Cidrs.append(contentsOf: countryRules.ipv4Cidrs)
        ipv6Cidrs.append(contentsOf: countryRules.ipv6Cidrs)

        let domainRules = await Self.resolveDomainRules(preferences.customDirectDomains)
        ipv4Cidrs.append(contentsOf: domainRules.ipv4Cidrs)
        ipv6Cidrs.append(contentsOf: domainRules.ipv6Cidrs)

        return DirectRouteRules(
            ipv4Cidrs: RoutePolicySnapshot.normalizedCidrs(
                from: ipv4Cidrs.joined(separator: "\n")
            ).valid,
            ipv6Cidrs: RoutePolicySnapshot.normalizedIPv6Cidrs(
                from: ipv6Cidrs.joined(separator: "\n")
            ).valid
        )
    }

    private static func resolveDomainRules(_ domains: [String]) async -> DirectRouteRules {
        guard !domains.isEmpty else {
            return DirectRouteRules(ipv4Cidrs: [], ipv6Cidrs: [])
        }

        return await Task.detached(priority: .utility) {
            var ipv4Cidrs: [String] = []
            var ipv6Cidrs: [String] = []
            var seen = Set<String>()

            for domain in domains.prefix(50) {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_UNSPEC,
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
                    let cidr = ip.contains(":") ? "\(ip)/128" : "\(ip)/32"
                    if seen.insert(cidr).inserted {
                        if ip.contains(":") {
                            ipv6Cidrs.append(cidr)
                        } else {
                            ipv4Cidrs.append(cidr)
                        }
                    }
                }
            }

            return DirectRouteRules(ipv4Cidrs: ipv4Cidrs, ipv6Cidrs: ipv6Cidrs)
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
