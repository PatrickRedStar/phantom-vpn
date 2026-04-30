//
//  UpstreamVpnRouteDetector.swift
//  GhostStream (macOS)
//

import Darwin
import Foundation
import PhantomKit
import SystemConfiguration

public struct UpstreamVpnRouteDetector {
    private struct InterfaceInfo {
        let index: UInt32
        let name: String
        let ipv4Addresses: [String]
    }

    public init() {}

    @MainActor
    public func snapshot(
        profile: VpnProfile?,
        preferences: PreferencesStore
    ) -> RoutePolicySnapshot {
        let mode = preferences.effectiveRoutingMode(profileSplitRouting: profile?.splitRouting)
        let manualCidrs = preferences.manualDirectCidrs
        let ghostTunAddress = profile.flatMap { Self.tunnelAddress(from: $0.tunAddr) }
        let interfaces = Self.activeUtunInterfaces(excludingIPv4Address: ghostTunAddress)
        let routes = Self.routes(on: interfaces)
        let dns = Self.dnsSnapshot(forInterfaceNames: Set(interfaces.map(\.name)))
        let serverCidrs = profile.map { Self.serverDirectCidrs(for: $0.serverAddr) } ?? []
        let providerName = Self.detectCiscoInstall() && !interfaces.isEmpty
            ? "Cisco Secure Client"
            : (!interfaces.isEmpty ? "Upstream VPN" : nil)

        return RoutePolicySnapshot(
            mode: mode,
            detectedUpstreamCidrs: mode == .layeredAuto ? routes.cidrs : [],
            manualDirectCidrs: manualCidrs,
            serverDirectCidrs: serverCidrs,
            upstreamDnsServers: dns.servers,
            upstreamDnsDomains: dns.domains,
            upstreamInterfaceNames: interfaces.map(\.name),
            upstreamProviderName: providerName,
            preserveScopedDns: preferences.preserveScopedDns
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

    private static func routes(on interfaces: [InterfaceInfo]) -> (cidrs: [String], interfaces: [String]) {
        let byIndex = Dictionary(uniqueKeysWithValues: interfaces.map { ($0.index, $0) })
        guard !byIndex.isEmpty else { return ([], []) }

        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP2, 0]
        var needed = 0
        guard sysctl(&mib, u_int(mib.count), nil, &needed, nil, 0) == 0, needed > 0 else {
            return ([], [])
        }

        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, u_int(mib.count), &buffer, &needed, nil, 0) == 0 else {
            return ([], [])
        }

        var cidrs: [String] = []
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

            guard prefix > 0 else { continue }
            let cidr = "\(destination)/\(prefix)"
            guard RoutePolicySnapshot.isValidIPv4Cidr(cidr), seen.insert(cidr).inserted else { continue }
            cidrs.append(cidr)
        }

        return (cidrs.sorted(by: cidrSort), interfaces.map(\.name))
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

        var prefix = 0
        var foundZero = false
        for byte in bytes {
            for bit in (0..<8).reversed() {
                let isOne = (byte & UInt8(1 << bit)) != 0
                if isOne {
                    guard !foundZero else { return nil }
                    prefix += 1
                } else {
                    foundZero = true
                }
            }
        }
        return prefix
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

    private static func serverDirectCidrs(for serverAddr: String) -> [String] {
        let host = hostPart(of: serverAddr)
        if RoutePolicySnapshot.isValidIPv4Cidr("\(host)/32") {
            return ["\(host)/32"]
        }

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
        return unique(output)
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
        func parts(_ cidr: String) -> ([Int], Int) {
            let split = cidr.split(separator: "/")
            let octets = split.first?
                .split(separator: ".")
                .compactMap { Int($0) } ?? []
            let prefix = split.count > 1 ? Int(split[1]) ?? 0 : 0
            return (octets, prefix)
        }
        let left = parts(lhs)
        let right = parts(rhs)
        return left.0 == right.0 ? left.1 < right.1 : left.0.lexicographicallyPrecedes(right.0)
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
