import Foundation

/// Runtime settings forwarded to the Rust tunnel via `phantom_runtime_start`.
public struct TunnelSettings: Codable {
    public var dnsLeakProtection: Bool
    public var ipv6Killswitch: Bool
    public var autoReconnect: Bool
    /// Requested TLS stream count from the UI. Current Rust runtime derives
    /// stream count internally, so this is carried for forward compatibility
    /// until the FFI/runtime consumes it.
    public var streams: Int

    enum CodingKeys: String, CodingKey {
        case dnsLeakProtection = "dns_leak_protection"
        case ipv6Killswitch = "ipv6_killswitch"
        case autoReconnect = "auto_reconnect"
        case streams
    }

    public init(
        dnsLeakProtection: Bool = true,
        ipv6Killswitch: Bool = true,
        autoReconnect: Bool = true,
        streams: Int = 8
    ) {
        self.dnsLeakProtection = dnsLeakProtection
        self.ipv6Killswitch = ipv6Killswitch
        self.autoReconnect = autoReconnect
        self.streams = max(2, min(16, streams))
    }
}
