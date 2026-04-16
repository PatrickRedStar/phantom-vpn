import Foundation

/// Runtime settings forwarded to the Rust tunnel via `phantom_runtime_start`.
public struct TunnelSettings: Codable {
    public var dnsLeakProtection: Bool
    public var ipv6Killswitch: Bool
    public var autoReconnect: Bool

    enum CodingKeys: String, CodingKey {
        case dnsLeakProtection = "dns_leak_protection"
        case ipv6Killswitch = "ipv6_killswitch"
        case autoReconnect = "auto_reconnect"
    }

    public init(
        dnsLeakProtection: Bool = true,
        ipv6Killswitch: Bool = true,
        autoReconnect: Bool = true
    ) {
        self.dnsLeakProtection = dnsLeakProtection
        self.ipv6Killswitch = ipv6Killswitch
        self.autoReconnect = autoReconnect
    }
}
