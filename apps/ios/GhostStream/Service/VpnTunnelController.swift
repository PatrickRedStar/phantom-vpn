// VpnTunnelController — NETunnelProviderManager wrapper. Installs the
// VPN configuration under Settings → VPN and starts / stops the Packet
// Tunnel Provider extension.

import Foundation
import NetworkExtension
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

    /// Loads the existing `NETunnelProviderManager` from system
    /// preferences, or creates a fresh one if none is installed.
    public func loadFromPreferences() async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = all.first(where: { candidate in
            (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleId
        }) {
            manager = existing
        } else if let anyManager = all.first {
            manager = anyManager
        } else {
            manager = NETunnelProviderManager()
        }
    }

    /// Installs `profile` into the system VPN configuration and starts the
    /// tunnel. Re-saves and reloads preferences so the system picks up
    /// the new `providerConfiguration`.
    ///
    /// - Throws: `VpnTunnelError.encoding` if profile JSON serialisation
    ///   fails, `VpnTunnelError.saveFailed` on save error, or
    ///   `VpnTunnelError.startFailed` if the connection won't start.
    public func installAndStart(profile: VpnProfile, preferences: PreferencesStore) async throws {
        if manager == nil { try await loadFromPreferences() }
        guard let manager else { throw VpnTunnelError.noManager }

        let proto = NETunnelProviderProtocol()
        proto.serverAddress = profile.serverAddr
        proto.providerBundleIdentifier = providerBundleId

        let encoder = JSONEncoder()
        let profileData: Data
        do {
            profileData = try encoder.encode(profile)
        } catch {
            throw VpnTunnelError.encoding
        }

        let prefsDto = PrefsDTO(
            dnsServers: preferences.dnsServers,
            splitRouting: preferences.splitRouting
        )
        let prefsData: Data
        do {
            prefsData = try encoder.encode(prefsDto)
        } catch {
            throw VpnTunnelError.encoding
        }

        proto.providerConfiguration = [
            "profile": profileData,
            "prefs": prefsData,
        ]

        manager.protocolConfiguration = proto
        manager.localizedDescription = profile.name
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        } catch {
            log.error("saveToPreferences failed: \(error.localizedDescription, privacy: .public)")
            throw VpnTunnelError.saveFailed(error.localizedDescription)
        }

        do {
            try manager.connection.startVPNTunnel()
        } catch {
            log.error("startVPNTunnel failed: \(error.localizedDescription, privacy: .public)")
            throw VpnTunnelError.startFailed(error.localizedDescription)
        }
    }

    /// Stops the tunnel, if any. No-op when no manager is loaded.
    public func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// Removes the installed VPN configuration from system preferences.
    public func remove() async throws {
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
    }

    // MARK: - DTOs

    /// Small subset of `PreferencesStore` shipped into the extension via
    /// `providerConfiguration`.
    private struct PrefsDTO: Encodable {
        var dnsServers: [String]?
        var splitRouting: Bool?
    }
}
