//
//  UpstreamVpnRouteDetector.swift
//  GhostStream (macOS)
//

import Darwin
import Foundation
import PhantomKit
import SystemConfiguration

public struct UpstreamVpnRouteDetector {
    public struct SnapshotInput: Sendable {
        public let mode: RoutingMode
        public let manualDirectCidrs: [String]
        public let manualDirectIpv6Cidrs: [String]
        public let preserveScopedDns: Bool
        public let serverAddr: String?
        public let tunAddr: String?

        public init(
            mode: RoutingMode,
            manualDirectCidrs: [String],
            manualDirectIpv6Cidrs: [String],
            preserveScopedDns: Bool,
            serverAddr: String?,
            tunAddr: String?
        ) {
            self.mode = mode
            self.manualDirectCidrs = manualDirectCidrs
            self.manualDirectIpv6Cidrs = manualDirectIpv6Cidrs
            self.preserveScopedDns = preserveScopedDns
            self.serverAddr = serverAddr
            self.tunAddr = tunAddr
        }
    }

    private struct InterfaceInfo {
        let index: UInt32
        let name: String
        let ipv4Addresses: [String]
    }

    private final class ServerCidrCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: (cidrs: [String], storedAt: Date)] = [:]

        /// `maxAge` nil — любая давность (фолбэк, когда свежий резолв не удался).
        func cidrs(for host: String, maxAge: TimeInterval? = nil) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = values[host] else { return nil }
            if let maxAge, Date().timeIntervalSince(entry.storedAt) > maxAge { return nil }
            return entry.cidrs
        }

        func store(_ cidrs: [String], for host: String) {
            guard !cidrs.isEmpty else { return }
            lock.lock()
            values[host] = (cidrs, Date())
            lock.unlock()
        }
    }

    private final class ServerResolveCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false
        private let continuation: CheckedContinuation<[String], Never>

        init(_ continuation: CheckedContinuation<[String], Never>) {
            self.continuation = continuation
        }

        func resume(_ cidrs: [String]) {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return }
            didResume = true
            continuation.resume(returning: cidrs)
        }
    }

    private static let serverCidrCache = ServerCidrCache()
    private static let serverResolveTimeout: DispatchTimeInterval = .milliseconds(1500)
    /// Адрес сервера/relay кэшируется не навсегда: после captive portal или
    /// переезда IP реле вечный кэш вёл Connect на старый адрес до рестарта.
    private static let serverCidrCacheTTL: TimeInterval = 300

    public init() {}

    /// `freshServerResolve` — резолвить адрес сервера мимо кэша (Connect).
    /// Результат всё равно кладётся в кэш, так что следующий poll монитора
    /// получит те же адреса и тот же routeHash.
    public func snapshot(_ input: SnapshotInput, freshServerResolve: Bool = false) async -> RoutePolicySnapshot {
        let serverCidrs = await Self.serverDirectCidrs(for: input.serverAddr, fresh: freshServerResolve)
        return await Task.detached(priority: .utility) {
            Self.makeSnapshot(input, serverCidrs: serverCidrs)
        }.value
    }

    private static func makeSnapshot(_ input: SnapshotInput, serverCidrs: [String]) -> RoutePolicySnapshot {
        let ghostTunAddress = input.tunAddr.flatMap { Self.tunnelAddress(from: $0) }
        let interfaces = Self.activeUtunInterfaces(excludingIPv4Address: ghostTunAddress)
        let routes = Self.routes(on: interfaces)
        let dns = Self.dnsSnapshot(forInterfaceNames: Set(interfaces.map(\.name)))
        let providerName = Self.detectCiscoInstall() && !interfaces.isEmpty
            ? "Cisco Secure Client"
            : (!interfaces.isEmpty ? "Upstream VPN" : nil)

        // ADR 0012: сырые маршруты upstream-VPN — только для UI-счётчика
        // и диагностики; в вычислении includedRoutes и в routeHash они
        // не участвуют (иерархию обеспечивает longest-prefix).
        let detected = input.mode == .layeredAuto ? routes.cidrs : []

        return RoutePolicySnapshot(
            mode: input.mode,
            detectedUpstreamCidrs: detected,
            manualDirectCidrs: input.manualDirectCidrs,
            manualDirectIpv6Cidrs: input.manualDirectIpv6Cidrs,
            serverDirectCidrs: serverCidrs,
            upstreamDnsServers: dns.servers,
            upstreamDnsDomains: dns.domains,
            upstreamInterfaceNames: interfaces.map(\.name),
            upstreamProviderName: providerName,
            preserveScopedDns: input.preserveScopedDns,
            upstreamHasBroadRoutes: input.mode == .layeredAuto && routes.hasBroadRoutes
        )
    }

    private static func activeUtunInterfaces(excludingIPv4Address excluded: String?) -> [InterfaceInfo] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }

        var byName: [String: (index: UInt32, addresses: [String])] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }

            let flags = item.pointee.ifa_flags
            guard (flags & UInt32(IFF_UP)) != 0,
                  let namePointer = item.pointee.ifa_name
            else { continue }

            let name = String(cString: namePointer)
            guard name.hasPrefix("utun"),
                  let addr = item.pointee.ifa_addr,
                  Int32(addr.pointee.sa_family) == AF_INET
            else { continue }

            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let ip = ipv4String(sin.sin_addr)
            guard ip != excluded else { continue }

            let index = if_nametoindex(namePointer)
            guard index > 0 else { continue }

            var entry = byName[name] ?? (index: index, addresses: [])
            if !entry.addresses.contains(ip) {
                entry.addresses.append(ip)
            }
            byName[name] = entry
        }

        return byName
            .map { InterfaceInfo(index: $0.value.index, name: $0.key, ipv4Addresses: $0.value.addresses) }
            .sorted { $0.name < $1.name }
    }

    private static func routes(
        on interfaces: [InterfaceInfo]
    ) -> (cidrs: [String], hasBroadRoutes: Bool, interfaces: [String]) {
        let byIndex = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.index, $0) })
        guard !byIndex.isEmpty else { return ([], false, []) }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP2, 0]
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else {
            return ([], false, [])
        }

        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, u_int(mib.count), &buffer, &needed, nil, 0) == 0 else {
            return ([], false, [])
        }

        var cidrs: [String] = []
        var hasBroadRoutes = false
        var seen = Set<String>()
        var offset = 0

        while offset + MemoryLayout<rt_msghdr2>.stride <= needed {
            let message = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr2.self)
            }
            let length = Int(message.rtm_msglen)
            guard length > 0, offset + length <= needed else { break }
            defer { offset += length }

            guard (Int32(message.rtm_flags) & RTF_UP) != 0,
                  let _ = byIndex[UInt32(message.rtm_index)]
            else { continue }

            let addrs = routeSockaddrs(in: buffer, start: offset, length: length, flags: Int(message.rtm_addrs))
            guard let destination = addrs.destination else { continue }

            let prefix: Int
            if (Int32(message.rtm_flags) & RTF_HOST) != 0 {
                prefix = 32
            } else if let maskPrefix = addrs.netmaskPrefix {
                prefix = maskPrefix
            } else {
                continue
            }

            // ADR 0012 guard: default (prefix 0) или сверхширокий маршрут
            // (≤ /7, напр. split-include «0.0.0.0/0» ставит 0/1+128/1) —
            // upstream-VPN претендует на весь трафик. В LPM-модели наши
            // комплемент-блоки специфичнее и «украдут» публичный трафик,
            // а корп-ресурсы без узких маршрутов лишатся корп-туннеля.
            // UI предупреждает по этому флагу.
            if prefix <= 7 {
                hasBroadRoutes = true
            }

            guard prefix > 0 else { continue }
            let cidr = "\(destination)/\(prefix)"
            guard RoutePolicySnapshot.isValidIPv4Cidr(cidr), seen.insert(cidr).inserted else { continue }
            cidrs.append(cidr)
        }

        return (cidrs.sorted(by: cidrSort), hasBroadRoutes, interfaces.map(\.name))
    }

    private static func routeSockaddrs(
        in buffer: [UInt8],
        start: Int,
        length: Int,
        flags: Int
    ) -> (destination: String?, netmaskPrefix: Int?) {
        var destination: String?
        var netmaskPrefix: Int?
        var cursor = start + MemoryLayout<rt_msghdr2>.stride
        let end = start + length

        for index in 0..<Int(RTAX_MAX) {
            guard (flags & (1 << index)) != 0 else { continue }
            guard cursor + MemoryLayout<sockaddr>.stride <= end else { break }

            let sockaddrValue: sockaddr = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: cursor, as: sockaddr.self)
            }

            if index == Int(RTAX_DST), Int32(sockaddrValue.sa_family) == AF_INET {
                destination = ipv4String(in: buffer, offset: cursor)
            } else if index == Int(RTAX_NETMASK) {
                netmaskPrefix = prefixLength(in: buffer, offset: cursor)
            }

            cursor += roundedSockaddrLength(sockaddrValue)
        }

        return (destination, netmaskPrefix)
    }

    private static func roundedSockaddrLength(_ sockaddr: sockaddr) -> Int {
        let length = Int(sockaddr.sa_len)
        let word = MemoryLayout<Int>.stride
        guard length > 0 else { return word }
        return 1 + ((length - 1) | (word - 1))
    }

    private static func ipv4String(in buffer: [UInt8], offset: Int) -> String? {
        guard offset + MemoryLayout<sockaddr_in>.stride <= buffer.count else { return nil }
        let sin = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: sockaddr_in.self)
        }
        return ipv4String(sin.sin_addr)
    }

    private static func ipv4String(_ address: in_addr) -> String {
        var addr = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    private static func prefixLength(in buffer: [UInt8], offset: Int) -> Int? {
        guard offset + MemoryLayout<sockaddr>.stride <= buffer.count else { return nil }
        let sockaddrValue: sockaddr = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: sockaddr.self)
        }

        var bytes = [UInt8](repeating: 0, count: 4)
        if Int32(sockaddrValue.sa_family) == AF_INET,
           offset + MemoryLayout<sockaddr_in>.stride <= buffer.count {
            let sin = buffer.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: sockaddr_in.self)
            }
            withUnsafeBytes(of: sin.sin_addr.s_addr) { raw in
                for index in 0..<min(4, raw.count) {
                    bytes[index] = raw[index]
                }
            }
        } else {
            let length = min(max(Int(sockaddrValue.sa_len) - 2, 0), 4)
            guard offset + 2 + length <= buffer.count else { return nil }
            for index in 0..<length {
                bytes[index] = buffer[offset + 2 + index]
            }
        }

        // Bit-математика вынесена в IPv4RouteMath (PhantomKit, под тестами).
        return IPv4RouteMath.prefixLength(fromMaskBytes: bytes)
    }

    private static func dnsSnapshot(forInterfaceNames names: Set<String>) -> (servers: [String], domains: [String]) {
        guard let store = SCDynamicStoreCreate(nil, "GhostStream.UpstreamVpnRouteDetector" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/DNS" as CFString) as? [String]
        else { return ([], []) }

        var servers: [String] = []
        var domains: [String] = []
        for key in keys {
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else {
                continue
            }
            let interfaceName = dict["InterfaceName"] as? String
            let scopedToUpstream = interfaceName.map { names.contains($0) } ?? false
            let hasSupplementalDomains = !(dict["SupplementalMatchDomains"] as? [String] ?? []).isEmpty

            guard scopedToUpstream || hasSupplementalDomains else { continue }
            servers.append(contentsOf: dict["ServerAddresses"] as? [String] ?? [])
            domains.append(contentsOf: dict["SupplementalMatchDomains"] as? [String] ?? [])
            domains.append(contentsOf: dict["SearchDomains"] as? [String] ?? [])
            if let domainName = dict["DomainName"] as? String {
                domains.append(domainName)
            }
        }

        return (unique(servers), unique(domains))
    }

    private static func serverDirectCidrs(for serverAddr: String?, fresh: Bool) async -> [String] {
        guard let serverAddr else { return [] }
        let host = hostPart(of: serverAddr)
        if RoutePolicySnapshot.isValidIPv4Cidr("\(host)/32") {
            return ["\(host)/32"]
        }
        if !fresh, let cached = serverCidrCache.cidrs(for: host, maxAge: serverCidrCacheTTL) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            let completion = ServerResolveCompletion(continuation)
            DispatchQueue.global(qos: .utility).async {
                let cidrs = blockingServerDirectCidrs(forHost: host)
                serverCidrCache.store(cidrs, for: host)
                completion.resume(cidrs.isEmpty ? (serverCidrCache.cidrs(for: host) ?? []) : cidrs)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + serverResolveTimeout) {
                completion.resume(serverCidrCache.cidrs(for: host) ?? [])
            }
        }
    }

    private static func blockingServerDirectCidrs(forHost host: String) -> [String] {
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
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            return []
        }
        defer { freeaddrinfo(result) }

        var output: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = result
        while let item = current {
            defer { current = item.pointee.ai_next }
            guard item.pointee.ai_family == AF_INET,
                  let addr = item.pointee.ai_addr
            else { continue }
            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            output.append("\(ipv4String(sin.sin_addr))/32")
        }
        // Сортировка: порядок A-записей от резолва к резолву плавает, а
        // serverDirectCidrs входит в routeHash — без неё истечение TTL
        // давало бы ложную смену политики.
        let cidrs = unique(output).sorted(by: cidrSort)
        serverCidrCache.store(cidrs, for: host)
        return cidrs
    }

    private static func hostPart(of serverAddr: String) -> String {
        let trimmed = serverAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let close = trimmed.firstIndex(of: "]") {
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        }
        return trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? trimmed
    }

    private static func tunnelAddress(from cidr: String) -> String? {
        cidr.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    private static func detectCiscoInstall() -> Bool {
        let paths = [
            "/Applications/Cisco/Cisco Secure Client.app",
            "/Applications/Cisco/Cisco Secure Client - Socket Filter.app",
            "/Applications/Cisco/Cisco AnyConnect Secure Mobility Client.app",
            "/Applications/Cisco/Cisco AnyConnect Socket Filter.app",
        ]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private static func cidrSort(_ lhs: String, _ rhs: String) -> Bool {
        IPv4RouteMath.cidrSortsBefore(lhs, rhs)
    }

    private static func unique(_ values: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            guard !value.isEmpty, seen.insert(value).inserted else { continue }
            output.append(value)
        }
        return output
    }
}
