// PacketTunnelProvider — NEPacketTunnelProvider entry point for GhostStream.
//
// Uses PhantomKit's actor-based PhantomBridge with push callbacks for
// status, logs, and inbound packets.

import Foundation
import NetworkExtension
import PhantomKit
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.ghoststream.vpn.PacketTunnel", category: "tunnel")

    private var outboundTask: Task<Void, Never>?

    // MARK: - In-process state

    private var lastStatusFrame: StatusFrame = .disconnected
    private var recentLogFrames: [LogFrame] = []
    private var activeProfile: VpnProfile?
    private var activeSettings: TunnelSettings?
    private var statusBroadcastGate = StatusBroadcastGate(minInterval: 1.0)

    // MARK: - Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                try await self.startTunnelAsync(completionHandler: completionHandler)
            } catch {
                self.log.error("startTunnel failed: \(error.localizedDescription, privacy: .public)")
                self.writeErrorSnapshot(error.localizedDescription)
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        outboundTask?.cancel()
        outboundTask = nil

        Task {
            await PhantomBridge.shared.stop()
            writeDisconnectedSnapshot()
            completionHandler()
        }
    }

    // MARK: - IPC (handleAppMessage)
    // Uses TunnelIpcBridge.Message / Response from PhantomKit so the
    // host app and extension share a single Codable wire format.

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let message: TunnelIpcBridge.Message
        do {
            message = try JSONDecoder().decode(TunnelIpcBridge.Message.self, from: messageData)
        } catch {
            completionHandler?(nil)
            return
        }

        switch message {
        case .getStatus:
            let response = TunnelIpcBridge.Response.status(lastStatusFrame)
            completionHandler?(try? JSONEncoder().encode(response))

        case .subscribeLogs(let sinceMs):
            let filtered = recentLogFrames.filter { $0.tsUnixMs > sinceMs }
            let response = TunnelIpcBridge.Response.logs(filtered)
            completionHandler?(try? JSONEncoder().encode(response))

        case .getCurrentProfile:
            let response = TunnelIpcBridge.Response.ok
            completionHandler?(try? JSONEncoder().encode(response))

        case .updateRoutePolicy(let snapshot):
            Task {
                do {
                    try await self.updateRoutePolicy(snapshot)
                    let response = TunnelIpcBridge.Response.ok
                    completionHandler?(try? JSONEncoder().encode(response))
                } catch {
                    let response = TunnelIpcBridge.Response.error(error.localizedDescription)
                    completionHandler?(try? JSONEncoder().encode(response))
                }
            }

        case .disconnect:
            outboundTask?.cancel()
            Task {
                await PhantomBridge.shared.stop()
                writeDisconnectedSnapshot()
                let response = TunnelIpcBridge.Response.ok
                completionHandler?(try? JSONEncoder().encode(response))
            }
        }
    }

    // MARK: - Start implementation

    private func startTunnelAsync(completionHandler: @escaping (Error?) -> Void) async throws {
        statusBroadcastGate.reset()
        writeStatePayload(VpnStatePayload(kind: .connecting))

        var profile = try loadProfile()
        let settings = loadSettings()
        profile = applyProviderConfigurationOverrides(to: profile)
        activeProfile = profile
        activeSettings = settings

        let networkSettings = try makeNetworkSettings(profile: profile, settings: settings)
        try await setTunnelNetworkSettings(networkSettings)

        var didCallCompletion = false

        // Start the Rust tunnel via PhantomKit actor bridge.
        do {
            try await PhantomBridge.shared.start(
                profile: profile,
                settings: settings,
                onStatus: { [weak self] frame in
                    guard let self else { return }
                    self.lastStatusFrame = frame

                    if self.statusBroadcastGate.shouldBroadcast(
                        frame,
                        now: ProcessInfo.processInfo.systemUptime
                    ) {
                        self.writeSnapshot(frame)
                    }

                    // Signal connected to NEPacketTunnelProvider on first .connected
                    if frame.state == .connected && !didCallCompletion {
                        didCallCompletion = true
                        completionHandler(nil)
                    }
                },
                onLog: { [weak self] frame in
                    guard let self else { return }
                    self.recentLogFrames.append(frame)
                    if self.recentLogFrames.count > 1000 {
                        self.recentLogFrames.removeFirst(self.recentLogFrames.count - 1000)
                    }
                },
                onInbound: { [weak self] data in
                    guard let self else { return }
                    self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: AF_INET)])
                }
            )
        } catch {
            await PhantomBridge.shared.stop()
            throw error
        }

        // If we haven't received .connected yet, call completion after a short delay
        // to avoid hanging the system VPN UI forever. The tunnel is running,
        // status callbacks will update the state.
        if !didCallCompletion {
            didCallCompletion = true
            completionHandler(nil)
        }

        // Outbound loop: drain packetFlow → Rust.
        outboundTask = Task.detached { [weak self] in
            await self?.outboundLoop()
        }
    }

    private func makeNetworkSettings(
        profile: VpnProfile,
        settings: TunnelSettings
    ) throws -> NEPacketTunnelNetworkSettings {
        let (tunIp, subnetMask) = try parseCidr(profile.tunAddr)
        let networkSettings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: tunnelRemoteAddress(for: profile.serverAddr)
        )
        networkSettings.mtu = NSNumber(value: 1350)

        let ipv4 = NEIPv4Settings(addresses: [tunIp], subnetMasks: [subnetMask])
        configureIPv4Routes(ipv4, for: profile, settings: settings)
        networkSettings.ipv4Settings = ipv4

        // iOS rejects NEIPv6Settings without at least one tunnel address.
        // Route IPv6 into the tunnel with a ULA address so unsupported IPv6
        // traffic is captured and dropped instead of leaking outside the VPN.
        if settings.ipv6Killswitch {
            let ipv6 = NEIPv6Settings(
                addresses: ["fd00:6768:6f73:7473::1"],
                networkPrefixLengths: [64]
            )
            let directIpv6Cidrs = directIpv6RoutesForRouteComputation(settings: settings)
            if shouldTunnelIPv6Traffic(settings: settings, directIpv6Cidrs: directIpv6Cidrs) {
                ipv6.includedRoutes = [NEIPv6Route.default()]
                let excludedRoutes = directIpv6Cidrs.compactMap(route(forIPv6CIDR:))
                if !excludedRoutes.isEmpty {
                    ipv6.excludedRoutes = excludedRoutes
                }
            } else {
                ipv6.excludedRoutes = [NEIPv6Route.default()]
                log.warning("split routing leaves IPv6 outside tunnel because no routeable IPv6 direct rules are available")
            }
            networkSettings.ipv6Settings = ipv6
        }

        let dnsServers = profile.dnsServers ?? ["1.1.1.1", "8.8.8.8"]
        let dns = NEDNSSettings(servers: dnsServers)
        if settings.dnsLeakProtection && shouldForceDnsMatchDomains(settings: settings) {
            dns.matchDomains = [""]
        }
        networkSettings.dnsSettings = dns

        return networkSettings
    }

    // MARK: - Profile loading

    private struct LastTunnelParams: Decodable {
        let dnsServers: [String]?
        let settings: TunnelSettings?

        enum CodingKeys: String, CodingKey {
            case profileId = "profile_id"
            case dnsServers = "dns_servers"
            case dnsServersCamel = "dnsServers"
            case settings
            case splitRouting = "split_routing"
            case directCidrs = "direct_cidrs"
            case manualDirectCidrs = "manual_direct_cidrs"
            case manualDirectIpv6Cidrs = "manual_direct_ipv6_cidrs"
            case routingMode = "routing_mode"
            case preserveScopedDns = "preserve_scoped_dns"
            case dnsLeakProtection = "dns_leak_protection"
            case ipv6Killswitch = "ipv6_killswitch"
            case autoReconnect = "auto_reconnect"
            case routePolicy = "route_policy"
            case streams
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            dnsServers = Self.decodeStringArray(.dnsServers, from: container)
                ?? Self.decodeStringArray(.dnsServersCamel, from: container)

            if let settings = try? container.decode(TunnelSettings.self, forKey: .settings) {
                self.settings = settings
                return
            }

            let splitRouting = Self.decodeBool(.splitRouting, from: container)
            let routingMode = Self.decodeString(.routingMode, from: container)
                .flatMap(RoutingMode.init(rawValue:))
                ?? RoutingMode.defaultValue(splitRouting: splitRouting)
            let manualDirectCidrs = Self.decodeStringArray(.manualDirectCidrs, from: container)
                ?? Self.decodeStringArray(.directCidrs, from: container)
                ?? []
            let manualDirectIpv6Cidrs = Self.decodeStringArray(.manualDirectIpv6Cidrs, from: container) ?? []

            self.settings = TunnelSettings(
                dnsLeakProtection: Self.decodeBool(.dnsLeakProtection, from: container) ?? true,
                ipv6Killswitch: Self.decodeBool(.ipv6Killswitch, from: container) ?? true,
                autoReconnect: Self.decodeBool(.autoReconnect, from: container) ?? true,
                routingMode: routingMode,
                manualDirectCidrs: manualDirectCidrs,
                manualDirectIpv6Cidrs: manualDirectIpv6Cidrs,
                preserveScopedDns: Self.decodeBool(.preserveScopedDns, from: container) ?? true,
                routePolicy: try? container.decode(RoutePolicySnapshot.self, forKey: .routePolicy),
                streams: Self.decodeInt(.streams, from: container) ?? 8
            )
        }

        private static func decodeBool(
            _ key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Bool? {
            try? container.decode(Bool.self, forKey: key)
        }

        private static func decodeInt(
            _ key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Int? {
            try? container.decode(Int.self, forKey: key)
        }

        private static func decodeString(
            _ key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> String? {
            try? container.decode(String.self, forKey: key)
        }

        private static func decodeStringArray(
            _ key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> [String]? {
            if let values = try? container.decode([String].self, forKey: key) {
                let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return cleaned.isEmpty ? nil : cleaned
            }
            guard let joined = try? container.decode(String.self, forKey: key) else { return nil }
            let cleaned = joined
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private func loadProfile() throws -> VpnProfile {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            throw ProviderError.missingProtocol
        }

        if let profileId = proto.providerConfiguration?["profileId"] as? String {
            guard let profile = resolveProfile(id: profileId) else {
                throw ProviderError.profileNotFound(profileId)
            }
            return profile
        }

        guard let profileData = proto.providerConfiguration?["profile"] as? Data else {
            throw ProviderError.missingProfile
        }
        do {
            return try JSONDecoder().decode(VpnProfile.self, from: profileData)
        } catch {
            throw ProviderError.decodeFailed(error.localizedDescription)
        }
    }

    private func loadSettings() -> TunnelSettings {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            return loadLastTunnelParams()?.settings ?? TunnelSettings()
        }

        if let settingsData = proto.providerConfiguration?["settings"] as? Data,
           let settings = try? JSONDecoder().decode(TunnelSettings.self, from: settingsData) {
            return settings
        }

        if let settingsJson = proto.providerConfiguration?["settings"] as? String,
           let data = settingsJson.data(using: .utf8),
           let settings = try? JSONDecoder().decode(TunnelSettings.self, from: data) {
            return settings
        }

        return loadLastTunnelParams()?.settings ?? TunnelSettings()
    }

    private func applyProviderConfigurationOverrides(to profile: VpnProfile) -> VpnProfile {
        var output = profile
        if let dnsServers = loadProviderDnsServers() {
            output.dnsServers = dnsServers
        }
        return output
    }

    private func loadProviderDnsServers() -> [String]? {
        if let proto = protocolConfiguration as? NETunnelProviderProtocol {
            if let dnsServers = normalizedDnsServers(proto.providerConfiguration?["dnsServers"]) {
                return dnsServers
            }
            if let dnsServers = normalizedDnsServers(proto.providerConfiguration?["dns_servers"]) {
                return dnsServers
            }
        }
        return loadLastTunnelParams()?.dnsServers
    }

    private func loadLastTunnelParams() -> LastTunnelParams? {
        guard
            let raw = UserDefaults(suiteName: "group.com.ghoststream.vpn")?
                .string(forKey: "last_tunnel_params"),
            let data = raw.data(using: .utf8)
        else { return nil }

        return try? JSONDecoder().decode(LastTunnelParams.self, from: data)
    }

    private func normalizedDnsServers(_ raw: Any?) -> [String]? {
        let values: [String]
        if let raw = raw as? [String] {
            values = raw
        } else if let raw = raw as? String {
            values = raw.split(separator: ",").map(String.init)
        } else {
            return nil
        }

        let cleaned = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    private func resolveProfile(id: String) -> VpnProfile? {
        let defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")
        guard
            let data = defaults?.data(forKey: "profiles.json"),
            let profiles = try? JSONDecoder().decode([VpnProfile].self, from: data),
            var profile = profiles.first(where: { $0.id == id })
        else { return nil }

        profile.certPem = Keychain.get("profile.\(id).cert")
        profile.keyPem  = Keychain.get("profile.\(id).key")
        return profile
    }

    // MARK: - Route settings

    private func updateRoutePolicy(_ snapshot: RoutePolicySnapshot) async throws {
        let profile: VpnProfile
        if let activeProfile {
            profile = activeProfile
        } else {
            profile = applyProviderConfigurationOverrides(to: try loadProfile())
        }

        var settings = activeSettings ?? loadSettings()
        settings.routingMode = snapshot.mode
        settings.manualDirectCidrs = snapshot.manualDirectCidrs
        settings.manualDirectIpv6Cidrs = snapshot.manualDirectIpv6Cidrs
        settings.preserveScopedDns = snapshot.preserveScopedDns
        settings.routePolicy = snapshot

        let networkSettings = try makeNetworkSettings(profile: profile, settings: settings)
        try await setTunnelNetworkSettings(networkSettings)

        activeProfile = profile
        activeSettings = settings
        log.info(
            "updated route policy mode=\(snapshot.mode.rawValue, privacy: .public) ipv4=\(snapshot.manualDirectCidrs.count, privacy: .public) ipv6=\(snapshot.manualDirectIpv6Cidrs.count, privacy: .public)"
        )
    }

    private func configureIPv4Routes(
        _ ipv4: NEIPv4Settings,
        for profile: VpnProfile,
        settings: TunnelSettings
    ) {
        let serverDirectCidrs = settings.routePolicy?.serverDirectCidrs ?? []
        let shouldUseSplitRoutes = settings.routingMode != .global
            || !serverDirectCidrs.isEmpty
            || (settings.routePolicy == nil && profile.splitRouting == true)
        guard shouldUseSplitRoutes else {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4.excludedRoutes = physicalServerExcludedRoutes(settings: settings)
            return
        }

        if let directCountries = profile.directCountries, !directCountries.isEmpty {
            log.warning(
                "split routing has directCountries=\(directCountries.joined(separator: ","), privacy: .public), but no country CIDR bundle is available; applying configured direct CIDRs only"
            )
        }

        let directCidrs = directCidrsForRouteComputation(settings: settings)
        let routes = PhantomBridge.computeVpnRoutes(directCidrs: directCidrs.joined(separator: "\n"))
            .compactMap { route in
                mask(forIPv4Prefix: route.prefix).map {
                    NEIPv4Route(destinationAddress: route.addr, subnetMask: $0)
                }
            }

        if routes.isEmpty {
            log.error("split routing route computation returned no routes; leaving IPv4 includedRoutes empty")
            ipv4.includedRoutes = []
        } else {
            ipv4.includedRoutes = routes
        }
        ipv4.excludedRoutes = physicalServerExcludedRoutes(settings: settings)
    }

    private func shouldForceDnsMatchDomains(settings: TunnelSettings) -> Bool {
        !(settings.routingMode == .layeredAuto && settings.preserveScopedDns)
    }

    private func directCidrsForRouteComputation(settings: TunnelSettings) -> [String] {
        var cidrs = settings.routePolicy?.serverDirectCidrs ?? []
        if settings.routingMode != .global {
            cidrs.append(contentsOf: settings.manualDirectCidrs)
        }
        if settings.routingMode == .layeredAuto {
            cidrs.append(contentsOf: settings.routePolicy?.detectedUpstreamCidrs ?? [])
            cidrs.append(contentsOf: settings.routePolicy?.manualDirectCidrs ?? [])
        }
        return RoutePolicySnapshot.normalizedCidrs(from: cidrs.joined(separator: "\n")).valid
    }

    private func directIpv6RoutesForRouteComputation(settings: TunnelSettings) -> [String] {
        guard settings.routingMode != .global else { return [] }
        var cidrs = settings.manualDirectIpv6Cidrs
        cidrs.append(contentsOf: settings.routePolicy?.manualDirectIpv6Cidrs ?? [])
        let normalized = RoutePolicySnapshot.normalizedIPv6Cidrs(from: cidrs.joined(separator: "\n")).valid
        let routeable = RoutePolicySnapshot.routeableIPv6Cidrs(normalized)
        if normalized.count > RoutePolicySnapshot.maxDirectIPv6RouteCount {
            log.error(
                "too many IPv6 direct routes (\(normalized.count, privacy: .public)); skipping IPv6 exceptions to keep tunnel startup reliable"
            )
        }
        return routeable
    }

    private func shouldTunnelIPv6Traffic(settings: TunnelSettings, directIpv6Cidrs: [String]) -> Bool {
        if settings.routingMode == .global { return true }
        return !directIpv6Cidrs.isEmpty
    }

    private func physicalServerExcludedRoutes(settings: TunnelSettings) -> [NEIPv4Route] {
        let upstreamCidrs = settings.routingMode == .layeredAuto
            ? (settings.routePolicy?.detectedUpstreamCidrs ?? [])
            : []
        return (settings.routePolicy?.serverDirectCidrs ?? []).compactMap { cidr in
            guard !cidrIsContainedInAny(cidr, containers: upstreamCidrs),
                  let route = route(forCIDR: cidr)
            else { return nil }
            return route
        }
    }

    private func route(forCIDR cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = UInt8(parts[1]),
              let subnetMask = mask(forIPv4Prefix: prefix)
        else { return nil }
        return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: subnetMask)
    }

    private func route(forIPv6CIDR cidr: String) -> NEIPv6Route? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...128).contains(prefix)
        else { return nil }
        return NEIPv6Route(
            destinationAddress: String(parts[0]),
            networkPrefixLength: NSNumber(value: prefix)
        )
    }

    private func mask(forIPv4Prefix prefix: UInt8) -> String? {
        guard prefix <= 32 else { return nil }
        guard prefix > 0 else { return "0.0.0.0" }
        let mask = UInt32.max << (32 - UInt32(prefix))
        let octets = [(mask >> 24) & 0xFF, (mask >> 16) & 0xFF, (mask >> 8) & 0xFF, mask & 0xFF]
        return octets.map { String($0) }.joined(separator: ".")
    }

    private func cidrIsContainedInAny(_ cidr: String, containers: [String]) -> Bool {
        guard let child = ipv4Range(forCIDR: cidr) else { return false }
        return containers.contains { container in
            guard let parent = ipv4Range(forCIDR: container) else { return false }
            return parent.lower <= child.lower && child.upper <= parent.upper
        }
    }

    private func ipv4Range(forCIDR cidr: String) -> (lower: UInt32, upper: UInt32)? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = UInt32(parts[1]),
              prefix <= 32,
              let ip = ipv4Integer(String(parts[0]))
        else { return nil }

        let hostMask: UInt32 = prefix == 32 ? 0 : (UInt32.max >> prefix)
        let networkMask = ~hostMask
        let lower = ip & networkMask
        return (lower, lower | hostMask)
    }

    private func ipv4Integer(_ address: String) -> UInt32? {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var output: UInt32 = 0
        for octet in octets {
            guard let value = UInt32(octet), value <= 255 else { return nil }
            output = (output << 8) | value
        }
        return output
    }

    // MARK: - Packet loop

    private func outboundLoop() async {
        while !Task.isCancelled {
            let packets: [Data] = await withCheckedContinuation { cont in
                self.packetFlow.readPackets { packets, _ in
                    cont.resume(returning: packets)
                }
            }
            if Task.isCancelled { break }
            for pkt in packets {
                await PhantomBridge.shared.submitInbound(pkt)
            }
        }
    }

    // MARK: - State broadcast

    private func writeStatePayload(_ payload: VpnStatePayload) {
        guard let defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn") else { return }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: "vpn.state.v1")
            defaults.set(Date().timeIntervalSince1970, forKey: "vpn.state.updatedAt.v1")
        }
        DarwinNotifications.post(DarwinNotifications.stateChanged)
    }

    private func writeSnapshot(_ frame: StatusFrame) {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.vpn")?
            .appendingPathComponent("snapshot.json"),
           let data = try? JSONEncoder().encode(frame) {
            try? data.write(to: url, options: .atomic)
        }

        // Also update the legacy state payload for VpnStateManager
        let payload: VpnStatePayload
        switch frame.state {
        case .disconnected:
            payload = VpnStatePayload(kind: .disconnected)
        case .connecting:
            payload = VpnStatePayload(kind: .connecting)
        case .reconnecting:
            payload = VpnStatePayload(kind: .connecting)
        case .connected:
            payload = VpnStatePayload(kind: .connected,
                                       since: Date().timeIntervalSince1970 - Double(frame.sessionSecs),
                                       serverName: frame.sni ?? frame.serverAddr ?? "")
        case .error:
            payload = VpnStatePayload(kind: .error, error: frame.lastError)
        }
        writeStatePayload(payload)
    }

    private func writeDisconnectedSnapshot() {
        statusBroadcastGate.reset()
        lastStatusFrame = .disconnected
        writeSnapshot(.disconnected)
    }

    private func writeErrorSnapshot(_ message: String) {
        statusBroadcastGate.reset()
        var frame = StatusFrame.disconnected
        frame.state = .error
        frame.lastError = message
        lastStatusFrame = frame
        writeSnapshot(frame)
    }

    // MARK: - Helpers

    private enum ProviderError: LocalizedError {
        case missingProtocol
        case missingProfile
        case profileNotFound(String)
        case decodeFailed(String)
        case badTunAddr(String)

        var errorDescription: String? {
            switch self {
            case .missingProtocol:         return "protocolConfiguration missing"
            case .missingProfile:          return "providerConfiguration['profile'] or ['profileId'] missing"
            case .profileNotFound(let id): return "Profile not found: \(id)"
            case .decodeFailed(let m):     return "providerConfiguration decode failed: \(m)"
            case .badTunAddr(let s):       return "Invalid tunAddr CIDR: \(s)"
            }
        }
    }

    private func parseCidr(_ cidr: String) throws -> (String, String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 32
        else {
            throw ProviderError.badTunAddr(cidr)
        }
        let ip = String(parts[0])
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        let octets = [(mask >> 24) & 0xFF, (mask >> 16) & 0xFF, (mask >> 8) & 0xFF, mask & 0xFF]
        return (ip, octets.map { String($0) }.joined(separator: "."))
    }

    private func hostPart(of addr: String) -> String {
        if let lastColon = addr.lastIndex(of: ":"),
           addr.firstIndex(of: ":") == lastColon {
            return String(addr[..<lastColon])
        }
        return addr
    }

    private func tunnelRemoteAddress(for addr: String) -> String {
        let host = hostPart(of: addr)
        return isIPv4Literal(host) ? host : "127.0.0.1"
    }

    private func isIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let byte = UInt8(part) else { return false }
            return String(byte) == String(part)
        }
    }
}
