// VpnProfile — Codable VPN profile DTO, mirrors android/.../data/VpnProfile.kt.

import Foundation

/// A VPN connection profile. Field shape mirrors the Android `VpnProfile`
/// data class one-to-one so that conn-string parsers and admin-API consumers
/// agree across platforms.
///
/// Note: `perAppMode` and `perAppList` are retained for cross-platform schema
/// compatibility but are **ignored on iOS** — the Packet Tunnel Provider
/// cannot route per-application on iOS.
///
/// Secrets (`certPem` / `keyPem`) are deliberately `Optional` so that the
/// struct can be safely round-tripped through UserDefaults without leaking PEMs
/// — see `sanitizedForUserDefaults`. The PEMs live in the shared Keychain.
public struct VpnProfile: Codable, Identifiable, Equatable {
    public var id: String
    public var name: String
    public var serverAddr: String
    public var serverName: String
    public var insecure: Bool
    public var certPem: String?
    public var keyPem: String?
    public var tunAddr: String
    public var dnsServers: [String]?
    public var splitRouting: Bool?
    public var directCountries: [String]?
    /// iOS-ignored. Retained for cross-platform schema parity only.
    public var perAppMode: String?
    /// iOS-ignored. Retained for cross-platform schema parity only.
    public var perAppList: [String]?
    public var cachedExpiresAt: Int64?
    public var cachedEnabled: Bool?
    public var cachedIsAdmin: Bool?
    public var cachedAdminServerCertFp: String?
    /// Original ghs:// connection string — required for phantom_runtime_start.
    public var connString: String?

    public init(
        id: String = UUID().uuidString,
        name: String = "Подключение",
        serverAddr: String = "",
        serverName: String = "",
        insecure: Bool = false,
        certPem: String? = nil,
        keyPem: String? = nil,
        tunAddr: String = "10.7.0.2/24",
        dnsServers: [String]? = nil,
        splitRouting: Bool? = nil,
        directCountries: [String]? = nil,
        perAppMode: String? = nil,
        perAppList: [String]? = nil,
        cachedExpiresAt: Int64? = nil,
        cachedEnabled: Bool? = nil,
        cachedIsAdmin: Bool? = nil,
        cachedAdminServerCertFp: String? = nil,
        connString: String? = nil
    ) {
        self.id = id
        self.name = name
        self.serverAddr = serverAddr
        self.serverName = serverName
        self.insecure = insecure
        self.certPem = certPem
        self.keyPem = keyPem
        self.tunAddr = tunAddr
        self.dnsServers = dnsServers
        self.splitRouting = splitRouting
        self.directCountries = directCountries
        self.perAppMode = perAppMode
        self.perAppList = perAppList
        self.cachedExpiresAt = cachedExpiresAt
        self.cachedEnabled = cachedEnabled
        self.cachedIsAdmin = cachedIsAdmin
        self.cachedAdminServerCertFp = cachedAdminServerCertFp
        self.connString = connString
    }

    /// Returns a copy with PEM secrets stripped — for persistence to
    /// UserDefaults while PEMs live in the Keychain.
    public var sanitizedForUserDefaults: VpnProfile {
        var copy = self
        copy.certPem = nil
        copy.keyPem = nil
        return copy
    }
}
