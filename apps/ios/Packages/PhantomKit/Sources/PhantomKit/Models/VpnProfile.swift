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
    /// Relay hop: when `true`, the transport dials `relayAddr` instead of
    /// `serverAddr` (SNI passthrough — `serverName` stays the same, TLS is
    /// end-to-end to the exit server). Mirrors Android `VpnProfile.relayEnabled`.
    public var relayEnabled: Bool?
    /// host:port of the relay hop. Only meaningful when `relayEnabled == true`.
    public var relayAddr: String?

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
        connString: String? = nil,
        relayEnabled: Bool? = nil,
        relayAddr: String? = nil
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
        self.relayEnabled = relayEnabled
        self.relayAddr = relayAddr
    }

    // CodingKeys must be enumerated so the explicit `init(from:)` below can
    // address each field individually. Mirrors the synthesised keys verbatim.
    enum CodingKeys: String, CodingKey {
        case id, name, serverAddr, serverName, insecure
        case certPem, keyPem
        case tunAddr, dnsServers, splitRouting, directCountries
        case perAppMode, perAppList
        case cachedExpiresAt, cachedEnabled, cachedIsAdmin, cachedAdminServerCertFp
        case connString
        case relayEnabled, relayAddr
    }

    /// Forgiving decoder: every non-Optional field falls back to the
    /// matching `init(…)` default when absent. Lets us add fields in Rust
    /// (or upstream Android) without silently breaking decoded profiles
    /// from older app installs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Подключение"
        self.serverAddr = try c.decodeIfPresent(String.self, forKey: .serverAddr) ?? ""
        self.serverName = try c.decodeIfPresent(String.self, forKey: .serverName) ?? ""
        self.insecure = try c.decodeIfPresent(Bool.self, forKey: .insecure) ?? false
        self.certPem = try c.decodeIfPresent(String.self, forKey: .certPem)
        self.keyPem = try c.decodeIfPresent(String.self, forKey: .keyPem)
        self.tunAddr = try c.decodeIfPresent(String.self, forKey: .tunAddr) ?? "10.7.0.2/24"
        self.dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers)
        self.splitRouting = try c.decodeIfPresent(Bool.self, forKey: .splitRouting)
        self.directCountries = try c.decodeIfPresent([String].self, forKey: .directCountries)
        self.perAppMode = try c.decodeIfPresent(String.self, forKey: .perAppMode)
        self.perAppList = try c.decodeIfPresent([String].self, forKey: .perAppList)
        self.cachedExpiresAt = try c.decodeIfPresent(Int64.self, forKey: .cachedExpiresAt)
        self.cachedEnabled = try c.decodeIfPresent(Bool.self, forKey: .cachedEnabled)
        self.cachedIsAdmin = try c.decodeIfPresent(Bool.self, forKey: .cachedIsAdmin)
        self.cachedAdminServerCertFp = try c.decodeIfPresent(String.self, forKey: .cachedAdminServerCertFp)
        self.connString = try c.decodeIfPresent(String.self, forKey: .connString)
        self.relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled)
        self.relayAddr = try c.decodeIfPresent(String.self, forKey: .relayAddr)
    }

    /// Address the transport actually dials: the relay endpoint when the
    /// relay hop is enabled and non-empty, otherwise the exit server itself.
    /// SNI (`serverName`) is never substituted — the relay forwards raw TLS
    /// by SNI (passthrough), so the ClientHello must keep the exit's name.
    public var effectiveServerAddr: String {
        if relayEnabled == true,
           let relay = relayAddr?.trimmingCharacters(in: .whitespacesAndNewlines),
           !relay.isEmpty {
            return relay
        }
        return serverAddr
    }

    /// `true` when the relay hop will actually be used by `effectiveServerAddr`.
    public var relayActive: Bool { effectiveServerAddr != serverAddr }

    /// Copy that dials `effectiveServerAddr`: `serverAddr` and the authority
    /// of `connString` point at the relay, SNI stays the exit's (passthrough).
    public var withRelayEndpoint: VpnProfile {
        guard relayActive else { return self }
        var copy = self
        copy.serverAddr = effectiveServerAddr
        copy.connString = connString.flatMap {
            ConnStringBuilder.replacingAuthority(in: $0, with: copy.serverAddr)
        }
        return copy
    }

    /// Returns a copy with PEM secrets stripped — for persistence to
    /// UserDefaults while PEMs live in the Keychain.
    public var sanitizedForUserDefaults: VpnProfile {
        var copy = self
        copy.certPem = nil
        copy.keyPem = nil
        return copy
    }

    /// Returns a copy safe to embed inside a `NETunnelProviderProtocol`'s
    /// `providerConfiguration` dictionary. Everything that gets serialised
    /// through this path is **persisted by the system in plaintext** under
    /// `/Library/Preferences/com.apple.networkextension*.plist`, so any
    /// PEM material or original `ghs://` connection string (whose userinfo
    /// is base64-encoded PEM) would be world-readable by any process with
    /// root. Strip them — the extension hydrates the cert / key from the
    /// shared Keychain at start time via `resolveProfile(id:)`.
    public var sanitizedForProviderConfiguration: VpnProfile {
        var copy = self
        copy.certPem = nil
        copy.keyPem = nil
        copy.connString = nil
        return copy
    }
}
