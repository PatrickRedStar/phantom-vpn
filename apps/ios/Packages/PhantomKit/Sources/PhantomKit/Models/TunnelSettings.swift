import Foundation

/// Runtime settings forwarded to the Rust tunnel via `phantom_runtime_start`.
public struct TunnelSettings: Codable {
    public var dnsLeakProtection: Bool
    public var ipv6Killswitch: Bool
    public var autoReconnect: Bool
    public var routingMode: RoutingMode
    public var manualDirectCidrs: [String]
    public var preserveScopedDns: Bool
    public var routePolicy: RoutePolicySnapshot?
    /// Requested TLS stream count from the UI. Current Rust runtime derives
    /// stream count internally, so this is carried for forward compatibility
    /// until the FFI/runtime consumes it.
    public var streams: Int

    enum CodingKeys: String, CodingKey {
        case dnsLeakProtection = "dns_leak_protection"
        case ipv6Killswitch = "ipv6_killswitch"
        case autoReconnect = "auto_reconnect"
        case routingMode = "routing_mode"
        case manualDirectCidrs = "manual_direct_cidrs"
        case preserveScopedDns = "preserve_scoped_dns"
        case routePolicy = "route_policy"
        case streams
    }

    public init(
        dnsLeakProtection: Bool = true,
        ipv6Killswitch: Bool = true,
        autoReconnect: Bool = true,
        routingMode: RoutingMode = .global,
        manualDirectCidrs: [String] = [],
        preserveScopedDns: Bool = true,
        routePolicy: RoutePolicySnapshot? = nil,
        streams: Int = 8
    ) {
        self.dnsLeakProtection = dnsLeakProtection
        self.ipv6Killswitch = ipv6Killswitch
        self.autoReconnect = autoReconnect
        self.routingMode = routingMode
        self.manualDirectCidrs = RoutePolicySnapshot.normalizedCidrs(
            from: manualDirectCidrs.joined(separator: "\n")
        ).valid
        self.preserveScopedDns = preserveScopedDns
        self.routePolicy = routePolicy
        self.streams = max(2, min(16, streams))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dnsLeakProtection = try container.decodeIfPresent(Bool.self, forKey: .dnsLeakProtection) ?? true
        ipv6Killswitch = try container.decodeIfPresent(Bool.self, forKey: .ipv6Killswitch) ?? true
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        routingMode = try container.decodeIfPresent(RoutingMode.self, forKey: .routingMode) ?? .global
        let cidrs = try container.decodeIfPresent([String].self, forKey: .manualDirectCidrs) ?? []
        manualDirectCidrs = RoutePolicySnapshot.normalizedCidrs(from: cidrs.joined(separator: "\n")).valid
        preserveScopedDns = try container.decodeIfPresent(Bool.self, forKey: .preserveScopedDns) ?? true
        routePolicy = try container.decodeIfPresent(RoutePolicySnapshot.self, forKey: .routePolicy)
        let rawStreams = try container.decodeIfPresent(Int.self, forKey: .streams) ?? 8
        streams = max(2, min(16, rawStreams))
    }
}
