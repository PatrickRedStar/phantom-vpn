import Darwin
import Foundation

public enum RoutingMode: String, Codable, CaseIterable, Sendable {
    case global
    case publicSplit
    case layeredAuto

    public static func defaultValue(splitRouting: Bool?) -> RoutingMode {
        splitRouting == true ? .publicSplit : .global
    }

    public var legacySplitRoutingValue: Bool? {
        switch self {
        case .global:
            return false
        case .publicSplit, .layeredAuto:
            return true
        }
    }
}

public struct RoutePolicySnapshot: Codable, Equatable, Sendable {
    public static let maxDirectIPv6RouteCount = 256

    public var mode: RoutingMode
    public var detectedUpstreamCidrs: [String]
    public var manualDirectCidrs: [String]
    public var manualDirectIpv6Cidrs: [String]
    public var serverDirectCidrs: [String]
    public var upstreamDnsServers: [String]
    public var upstreamDnsDomains: [String]
    public var upstreamInterfaceNames: [String]
    public var upstreamProviderName: String?
    public var preserveScopedDns: Bool
    public var routeHash: String
    public var generatedAtUnixMs: UInt64

    enum CodingKeys: String, CodingKey {
        case mode
        case detectedUpstreamCidrs = "detected_upstream_cidrs"
        case manualDirectCidrs = "manual_direct_cidrs"
        case manualDirectIpv6Cidrs = "manual_direct_ipv6_cidrs"
        case serverDirectCidrs = "server_direct_cidrs"
        case upstreamDnsServers = "upstream_dns_servers"
        case upstreamDnsDomains = "upstream_dns_domains"
        case upstreamInterfaceNames = "upstream_interface_names"
        case upstreamProviderName = "upstream_provider_name"
        case preserveScopedDns = "preserve_scoped_dns"
        case routeHash = "route_hash"
        case generatedAtUnixMs = "generated_at_unix_ms"
    }

    public init(
        mode: RoutingMode = .global,
        detectedUpstreamCidrs: [String] = [],
        manualDirectCidrs: [String] = [],
        manualDirectIpv6Cidrs: [String] = [],
        serverDirectCidrs: [String] = [],
        upstreamDnsServers: [String] = [],
        upstreamDnsDomains: [String] = [],
        upstreamInterfaceNames: [String] = [],
        upstreamProviderName: String? = nil,
        preserveScopedDns: Bool = true,
        routeHash: String = "",
        generatedAtUnixMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.mode = mode
        self.detectedUpstreamCidrs = Self.uniqueCidrs(detectedUpstreamCidrs)
        self.manualDirectCidrs = Self.uniqueCidrs(manualDirectCidrs)
        self.manualDirectIpv6Cidrs = Self.uniqueIPv6Cidrs(manualDirectIpv6Cidrs)
        self.serverDirectCidrs = Self.uniqueCidrs(serverDirectCidrs)
        self.upstreamDnsServers = Self.uniqueStrings(upstreamDnsServers)
        self.upstreamDnsDomains = Self.uniqueStrings(upstreamDnsDomains)
        self.upstreamInterfaceNames = Self.uniqueStrings(upstreamInterfaceNames)
        self.upstreamProviderName = upstreamProviderName
        self.preserveScopedDns = preserveScopedDns
        self.generatedAtUnixMs = generatedAtUnixMs

        if routeHash.isEmpty {
            self.routeHash = Self.stableHash([
                mode.rawValue,
                self.detectedUpstreamCidrs.joined(separator: ","),
                self.manualDirectCidrs.joined(separator: ","),
                self.manualDirectIpv6Cidrs.joined(separator: ","),
                self.serverDirectCidrs.joined(separator: ","),
                self.upstreamDnsServers.joined(separator: ","),
                self.upstreamDnsDomains.joined(separator: ","),
                self.upstreamInterfaceNames.joined(separator: ","),
                upstreamProviderName ?? "",
                preserveScopedDns ? "preserveScopedDns=1" : "preserveScopedDns=0",
            ])
        } else {
            self.routeHash = routeHash
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generatedAtUnixMs = try container.decodeIfPresent(
            UInt64.self,
            forKey: .generatedAtUnixMs
        ) ?? UInt64(Date().timeIntervalSince1970 * 1000)

        self.init(
            mode: try container.decodeIfPresent(RoutingMode.self, forKey: .mode) ?? .global,
            detectedUpstreamCidrs: try container.decodeIfPresent(
                [String].self,
                forKey: .detectedUpstreamCidrs
            ) ?? [],
            manualDirectCidrs: try container.decodeIfPresent(
                [String].self,
                forKey: .manualDirectCidrs
            ) ?? [],
            manualDirectIpv6Cidrs: try container.decodeIfPresent(
                [String].self,
                forKey: .manualDirectIpv6Cidrs
            ) ?? [],
            serverDirectCidrs: try container.decodeIfPresent(
                [String].self,
                forKey: .serverDirectCidrs
            ) ?? [],
            upstreamDnsServers: try container.decodeIfPresent(
                [String].self,
                forKey: .upstreamDnsServers
            ) ?? [],
            upstreamDnsDomains: try container.decodeIfPresent(
                [String].self,
                forKey: .upstreamDnsDomains
            ) ?? [],
            upstreamInterfaceNames: try container.decodeIfPresent(
                [String].self,
                forKey: .upstreamInterfaceNames
            ) ?? [],
            upstreamProviderName: try container.decodeIfPresent(
                String.self,
                forKey: .upstreamProviderName
            ),
            preserveScopedDns: try container.decodeIfPresent(
                Bool.self,
                forKey: .preserveScopedDns
            ) ?? true,
            routeHash: try container.decodeIfPresent(String.self, forKey: .routeHash) ?? "",
            generatedAtUnixMs: generatedAtUnixMs
        )
    }

    public var directCidrsForRouteComputation: [String] {
        Self.uniqueCidrs(detectedUpstreamCidrs + manualDirectCidrs + serverDirectCidrs)
    }

    public var directIpv6CidrsForRouteComputation: [String] {
        Self.routeableIPv6Cidrs(manualDirectIpv6Cidrs)
    }

    public static func normalizedCidrs(from text: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let withoutComment = line.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? ""
            let cidr = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cidr.isEmpty else { continue }

            if isValidIPv4Cidr(cidr) {
                if seen.insert(cidr).inserted {
                    valid.append(cidr)
                }
            } else {
                invalid.append(cidr)
            }
        }

        return (valid, invalid)
    }

    public static func isValidIPv4Cidr(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...32).contains(prefix)
        else { return false }

        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part)
            else { return false }
            return (0...255).contains(value)
        }
    }

    public static func normalizedIPv6Cidrs(from text: String) -> (valid: [String], invalid: [String]) {
        var valid: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let withoutComment = line.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).first.map(String.init) ?? ""
            let cidr = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cidr.isEmpty else { continue }

            if isValidIPv6Cidr(cidr) {
                let normalized = cidr.lowercased()
                if seen.insert(normalized).inserted {
                    valid.append(normalized)
                }
            } else {
                invalid.append(cidr)
            }
        }

        return (valid, invalid)
    }

    public static func isValidIPv6Cidr(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...128).contains(prefix)
        else { return false }

        var address = in6_addr()
        return String(parts[0]).withCString { rawAddress in
            inet_pton(AF_INET6, rawAddress, &address) == 1
        }
    }

    public static func routeableIPv6Cidrs(
        _ cidrs: [String],
        maxRoutes: Int = maxDirectIPv6RouteCount
    ) -> [String] {
        let normalized = uniqueIPv6Cidrs(cidrs)
        guard normalized.count <= maxRoutes else { return [] }
        return normalized
    }

    /// Максимум IPv4 CIDR от upstream-детектора ПОСЛЕ агрегации.
    /// Зеркалит `maxDirectIPv6RouteCount`: без лимита Cisco dynamic
    /// split-include (сотни /32, меняются на лету) давал комплемент в
    /// тысячи `includedRoutes` на каждый `setTunnelNetworkSettings`
    /// и непрерывный дребезг `routeHash` (июльский instant-disconnect
    /// на пресете Cisco).
    public static let maxDetectedIPv4RouteCount = 192

    /// Агрегирует список IPv4 CIDR до стабильного и небольшого набора
    /// супернетов: сначала все префиксы длиннее /24 округляются до /24;
    /// если CIDR-ов всё ещё больше `maxCount`, лестница опускается до
    /// /20, затем /16. Вложенные подсети схлопываются в контейнер.
    ///
    /// Семантика для layeredAuto: «direct»-зона вокруг корпоративных
    /// адресов расширяется до супернета — соседний с корпоративным
    /// трафик уходит через upstream VPN, НЕ мимо него (ADR 0006:
    /// упорядоченная иерархия Cisco → GhostStream сохраняется). Взамен
    /// новые динамические /32 от Cisco почти всегда попадают в уже
    /// существующий супернет — routeHash перестаёт дребезжать.
    ///
    /// Если даже на /16 набор больше `maxCount` (аномалия), список
    /// обрезается до первых `maxCount` по числовому порядку — лучше
    /// частичная direct-зона, чем отказ NE от тысяч маршрутов.
    public static func aggregatedUpstreamCidrs(
        _ cidrs: [String],
        maxCount: Int = maxDetectedIPv4RouteCount
    ) -> [String] {
        struct Net {
            let base: UInt32
            let prefix: Int
        }

        func parse(_ cidr: String) -> Net? {
            let parts = cidr.split(separator: "/", maxSplits: 1)
            guard parts.count == 2,
                  let prefix = Int(parts[1]), (0...32).contains(prefix)
            else { return nil }
            let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4 else { return nil }
            var value: UInt32 = 0
            for octet in octets {
                guard let byte = UInt32(octet), byte <= 255 else { return nil }
                value = (value << 8) | byte
            }
            let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
            return Net(base: value & mask, prefix: prefix)
        }

        func render(_ net: Net) -> String {
            let o1 = (net.base >> 24) & 0xFF
            let o2 = (net.base >> 16) & 0xFF
            let o3 = (net.base >> 8) & 0xFF
            let o4 = net.base & 0xFF
            return "\(o1).\(o2).\(o3).\(o4)/\(net.prefix)"
        }

        let parsed = cidrs.compactMap(parse)
        guard !parsed.isEmpty else { return [] }

        for target in [24, 20, 16] {
            var rounded: [UInt32: Int] = [:]
            for net in parsed {
                let prefix = min(net.prefix, target)
                let mask: UInt32 = prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix)
                let base = net.base & mask
                // Держим самый широкий префикс на базу.
                if let existing = rounded[base] {
                    rounded[base] = min(existing, prefix)
                } else {
                    rounded[base] = prefix
                }
            }
            var nets: [Net] = rounded.map { entry in
                Net(base: entry.key, prefix: entry.value)
            }
            nets.sort { lhs, rhs in
                if lhs.base == rhs.base {
                    return lhs.prefix < rhs.prefix
                }
                return lhs.base < rhs.base
            }
            // Схлопываем вложенные: контейнер идёт раньше по сортировке.
            var collapsed: [Net] = []
            for net in nets {
                if let last = collapsed.last {
                    let mask: UInt32 = last.prefix == 0 ? 0 : ~UInt32(0) << (32 - last.prefix)
                    if (net.base & mask) == last.base && net.prefix >= last.prefix {
                        continue
                    }
                }
                collapsed.append(net)
            }
            nets = collapsed

            if nets.count <= maxCount || target == 16 {
                if nets.count > maxCount {
                    nets = Array(nets.prefix(maxCount))
                }
                return nets.map(render)
            }
        }
        return []
    }

    public static func stableHash(_ parts: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in parts.joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    private static func uniqueCidrs(_ cidrs: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for cidr in cidrs.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard isValidIPv4Cidr(cidr), seen.insert(cidr).inserted else { continue }
            output.append(cidr)
        }
        return output
    }

    private static func uniqueIPv6Cidrs(_ cidrs: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for cidr in cidrs.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
            guard isValidIPv6Cidr(cidr), seen.insert(cidr).inserted else { continue }
            output.append(cidr)
        }
        return output
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            output.append(value)
        }
        return output
    }
}
