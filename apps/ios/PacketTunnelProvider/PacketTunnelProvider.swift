// PacketTunnelProvider — NEPacketTunnelProvider entry point for GhostStream.
//
// Uses PhantomKit's actor-based PhantomBridge with push callbacks for
// status, logs, and inbound packets.

import Foundation
import NetworkExtension
import PhantomKit
import UserNotifications
import WidgetKit
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.ghoststream.client.PacketTunnel", category: "tunnel")

    private var outboundTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?

    // MARK: - In-process state

    /// Guards `lastStatusFrame`, `recentLogFrames`, `statusBroadcastGate` and
    /// the start-completion flag: Rust callbacks (PhantomBridge actor), IPC
    /// (`handleAppMessage`) and the start/stop Tasks touch them from
    /// different threads. Same pattern as the macOS provider.
    private let stateLock = NSLock()
    private var lastStatusFrame: StatusFrame = .disconnected
    private var recentLogFrames: [LogFrame] = []
    private var activeProfile: VpnProfile?
    private var activeSettings: TunnelSettings?
    private var statusBroadcastGate = StatusBroadcastGate(minInterval: 1.0)
    private var sessionClock = SessionClock()
    private var lastSurfaceKind: VpnStatePayload.Kind?

    @discardableResult
    private func withStateLock<T>(_ block: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block()
    }

    // MARK: - Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                try await self.startTunnelAsync(completionHandler: completionHandler)
            } catch {
                self.appendProviderLog("startTunnel failed: \(error.localizedDescription)", level: "ERR")
                self.writeErrorSnapshot(error.localizedDescription)
                // A fatal-marker refusal (On-Demand retry) adds nothing:
                // keep the tail of the session that actually failed.
                if case ProviderError.fatalStop = error {} else { self.persistLogTail() }
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        appendProviderLog("stopTunnel reason=\(reason.rawValue)")
        outboundTask?.cancel()
        outboundTask = nil
        memoryTask?.cancel()
        memoryTask = nil

        Task {
            await PhantomBridge.shared.stop()
            withStateLock { sessionClock.reset() }
            persistLogTail()
            UserDefaults(suiteName: SharedKeys.appGroup)?.removeObject(forKey: SharedKeys.tunnelMemoryMiB)
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
            let response = TunnelIpcBridge.Response.status(withStateLock { lastStatusFrame })
            completionHandler?(try? JSONEncoder().encode(response))

        case .subscribeLogs(let sinceUs):
            // µs-курсор (см. TunnelIpcBridge.Message): мс-гранулярность
            // теряла фреймы, попавшие в ту же миллисекунду, что и максимум
            // предыдущего батча.
            let filtered = withStateLock { recentLogFrames.filter { $0.timestampUs > sinceUs } }
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
            memoryTask?.cancel()
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
        // On-Demand must not restart a profile that stopped on a fatal
        // reason (revoked / expired access, clock): no handshake, same
        // reason back, until the user connects from the app (ADR 0018).
        if let profileId = (protocolConfiguration as? NETunnelProviderProtocol)?
            .providerConfiguration?["profileId"] as? String,
           let marker = UserDefaults(suiteName: SharedKeys.appGroup)?
            .dictionary(forKey: SharedKeys.fatalStop) as? [String: String],
           marker["profileId"] == profileId {
            throw ProviderError.fatalStop(marker["reason"] ?? "VPN error")
        }

        withStateLock {
            statusBroadcastGate.reset()
            sessionClock.reset()
            lastStatusFrame = .disconnected
        }
        writeStatePayload(VpnStatePayload(kind: .connecting))

        var profile = try loadProfile()
        let settings = loadSettings()
        let relayOn = profile.relayActive
        profile = applyProviderConfigurationOverrides(to: profile)
        activeProfile = profile
        activeSettings = settings

        let networkSettings = try makeNetworkSettings(profile: profile, settings: settings)
        try await setTunnelNetworkSettings(networkSettings)
        appendProviderLog(
            "tunnel start relay=\(relayOn ? "on" : "off") target=\(profile.serverAddr) sni=\(profile.serverName)"
                + " mtu=\(networkSettings.mtu?.intValue ?? 0)"
                + " excludedRoutes=\(networkSettings.ipv4Settings?.excludedRoutes?.count ?? 0)",
            isPublic: false
        )

        // Read and set only under `stateLock`: the status callback and the
        // fallback below race, and a second completion call traps the extension.
        var didCallCompletion = false
        let claimCompletion = { [weak self] () -> Bool in
            self?.withStateLock { () -> Bool in
                defer { didCallCompletion = true }
                return !didCallCompletion
            } ?? false
        }

        let profileId = profile.id
        let profileName = profile.name

        // Start the Rust tunnel via PhantomKit actor bridge.
        do {
            try await PhantomBridge.shared.start(
                profile: profile,
                settings: settings,
                onStatus: { [weak self] coreFrame in
                    guard let self else { return }
                    let (frame, previousState, broadcast) = self.withStateLock { () -> (StatusFrame, ConnState, Bool) in
                        let previous = self.lastStatusFrame.state
                        let frame = self.sessionClock.stamp(coreFrame)
                        self.lastStatusFrame = frame
                        let pass = self.statusBroadcastGate.shouldBroadcast(
                            frame,
                            now: ProcessInfo.processInfo.systemUptime
                        )
                        return (frame, previous, pass)
                    }
                    if broadcast {
                        self.writeSnapshot(frame)
                    }
                    if frame.state != previousState {
                        self.appendProviderLog(
                            "state \(previousState.rawValue) → \(frame.state.rawValue)"
                                + " streams=\(frame.streamsUp)/\(frame.nStreams)"
                        )
                    }

                    // Signal connected to NEPacketTunnelProvider on first .connected
                    if frame.state == .connected && claimCompletion() {
                        completionHandler(nil)
                    }

                    // The core reconnects by itself (ADR 0018); NE only shows it.
                    if (frame.state == .reconnecting) != (previousState == .reconnecting) {
                        self.reasserting = frame.state == .reconnecting
                    }

                    // The core reconnects on its own after network failures;
                    // `.error` means a fatal reason (config, certificate,
                    // revoked access, wrong clock) and the runtime has given
                    // up. A tunnel without a runtime is a black hole — stop
                    // and leave the reason in the snapshot for the app.
                    if frame.state == .error && previousState != .error {
                        let err = NSError(
                            domain: "GhostStream",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: frame.lastError ?? "VPN error"]
                        )
                        self.log.error("runtime error: \(err.localizedDescription, privacy: .public)")
                        UserDefaults(suiteName: SharedKeys.appGroup)?.set(
                            ["profileId": profileId, "reason": err.localizedDescription],
                            forKey: SharedKeys.fatalStop
                        )
                        self.notifyFatalStop(err.localizedDescription, profileName: profileName)
                        self.persistLogTail()
                        if claimCompletion() {
                            completionHandler(err)
                            Task { await PhantomBridge.shared.stop() }
                        } else {
                            self.cancelTunnelWithError(err)
                        }
                    }
                },
                onLog: { [weak self] frame in
                    self?.appendCoreLog(frame)
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

        // If we haven't received .connected yet, call completion now
        // to avoid hanging the system VPN UI forever. The tunnel is running,
        // status callbacks will update the state.
        if claimCompletion() {
            completionHandler(nil)
        }

        // Outbound loop: drain packetFlow → Rust.
        outboundTask = Task.detached { [weak self] in
            await self?.outboundLoop()
        }

        memoryTask?.cancel()
        memoryTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                self?.logMemoryFootprint()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    /// Jetsam watch: iOS kills the extension at ~50 MiB footprint. One line
    /// a minute in the Logs screen shows how close we run; the value also
    /// goes to the App Group for the dashboard («Память туннеля»).
    private func logMemoryFootprint() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mib = 1_048_576.0
        let footprint = kr == KERN_SUCCESS ? Double(info.phys_footprint) / mib : -1
        let available = Double(os_proc_available_memory()) / mib
        appendProviderLog(String(format: "memory footprint=%.1fMiB available=%.1fMiB", footprint, available))
        if footprint > 0 {
            UserDefaults(suiteName: SharedKeys.appGroup)?.set(footprint, forKey: SharedKeys.tunnelMemoryMiB)
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
        networkSettings.mtu = NSNumber(value: 1300)  // as Android, ADR 0019

        let ipv4 = NEIPv4Settings(addresses: [tunIp], subnetMasks: [subnetMask])
        configureIPv4Routes(ipv4, for: profile, settings: settings)
        networkSettings.ipv4Settings = ipv4

        // iOS rejects NEIPv6Settings without at least one tunnel address.
        // Route IPv6 into the tunnel with a ULA address so unsupported IPv6
        // traffic is captured and dropped instead of leaking outside the VPN —
        // in split modes too: apps fall back to IPv4, which follows the split
        // rules. Only explicit direct IPv6 rules bypass the tunnel.
        if settings.ipv6Killswitch {
            let ipv6 = NEIPv6Settings(
                addresses: ["fd00:6768:6f73:7473::1"],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            let excludedRoutes = directIpv6RoutesForRouteComputation(settings: settings)
                .compactMap(route(forIPv6CIDR:))
            if !excludedRoutes.isEmpty {
                ipv6.excludedRoutes = excludedRoutes
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
                streams: Self.decodeInt(.streams, from: container)
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
        // Relay (ADR 0013): TCP goes to the relay, SNI stays the exit's.
        var output = profile.withRelayEndpoint
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
            let raw = UserDefaults(suiteName: "group.com.ghoststream.client")?
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
        let defaults = UserDefaults(suiteName: "group.com.ghoststream.client")
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
        let adminGatewayHost = AdminGateway.host(forTunAddr: profile.tunAddr)
        let applyFullTunnel = {
            // Full tunnel leaves LAN, link-local and multicast reachable
            // (ADR 0019); our own subnet (admin API) stays in the tunnel —
            // more specific than the excluded 10/8.
            ipv4.includedRoutes = [NEIPv4Route.default()] + [self.route(forCIDR: profile.tunAddr)].compactMap { $0 }
            ipv4.excludedRoutes = self.physicalServerExcludedRoutes(
                settings: settings,
                preservingHost: adminGatewayHost
            ) + Self.specialRanges.compactMap(self.route(forCIDR:))
        }
        guard shouldUseSplitRoutes else {
            applyFullTunnel()
            return
        }

        if let directCountries = profile.directCountries, !directCountries.isEmpty {
            log.warning(
                "split routing has directCountries=\(directCountries.joined(separator: ","), privacy: .public), but no country CIDR bundle is available; applying configured direct CIDRs only"
            )
        }

        let directCidrs = directCidrsForRouteComputation(settings: settings)
        var routes = PhantomBridge.computeVpnRoutes(directCidrs: directCidrs.joined(separator: "\n"))
            .compactMap { route in
                mask(forIPv4Prefix: route.prefix).map {
                    NEIPv4Route(destinationAddress: route.addr, subnetMask: $0)
                }
            }
        // The core returns nothing when the list is over its 256 KiB input
        // cap or unparsable. Split routes of just the admin /32 would send
        // everything else outside the tunnel — take the full tunnel instead.
        guard !routes.isEmpty else {
            appendProviderLog(
                "split routing: no routes computed for \(directCidrs.count) direct CIDRs; using full tunnel",
                level: "ERR"
            )
            applyFullTunnel()
            return
        }
        if let adminRoute = route(forIPv4Host: adminGatewayHost),
           !routes.contains(where: { $0.destinationAddress == adminRoute.destinationAddress }) {
            routes.append(adminRoute)
        }

        ipv4.includedRoutes = routes
        ipv4.excludedRoutes = physicalServerExcludedRoutes(
            settings: settings,
            preservingHost: adminGatewayHost
        )
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
            // ADR 0012: detectedUpstreamCidrs не вычитаются — корп-маршруты
            // upstream-VPN выигрывают по longest-prefix сами (паритет с macOS;
            // layeredAuto на iOS фактически не используется).
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

    private func physicalServerExcludedRoutes(
        settings: TunnelSettings,
        preservingHost host: String? = nil
    ) -> [NEIPv4Route] {
        // ADR 0012: серверный exclude ставится всегда (containment-check по
        // detected убран — см. macOS provider).
        return (settings.routePolicy?.serverDirectCidrs ?? []).compactMap { cidr in
            guard !cidrContainsIPv4Host(cidr, host),
                  let route = route(forCIDR: cidr)
            else { return nil }
            return route
        }
    }

    /// Same ranges as Android `SPECIAL_RANGES` / core `special_ranges()`,
    /// minus 127/8: NE rejects it («Destination address is loopback») and
    /// loopback never enters the tunnel anyway.
    private static let specialRanges = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "224.0.0.0/4", "240.0.0.0/4",
    ]

    /// Destination is the network address, so a host CIDR (tunAddr
    /// 10.7.0.2/24) yields the subnet route 10.7.0.0/24.
    private func route(forCIDR cidr: String) -> NEIPv4Route? {
        guard let range = ipv4Range(forCIDR: cidr),
              let prefix = cidr.split(separator: "/").last.flatMap({ UInt8($0) }),
              let subnetMask = mask(forIPv4Prefix: prefix)
        else { return nil }
        let network = [24, 16, 8, 0].map { String((range.lower >> UInt32($0)) & 0xFF) }
        return NEIPv4Route(destinationAddress: network.joined(separator: "."), subnetMask: subnetMask)
    }

    private func route(forIPv4Host host: String) -> NEIPv4Route? {
        guard ipv4Integer(host) != nil,
              let hostMask = mask(forIPv4Prefix: 32)
        else { return nil }
        return NEIPv4Route(destinationAddress: host, subnetMask: hostMask)
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

    private func cidrContainsIPv4Host(_ cidr: String, _ host: String?) -> Bool {
        guard let host,
              let range = ipv4Range(forCIDR: cidr),
              let address = ipv4Integer(host)
        else { return false }
        return range.lower <= address && address <= range.upper
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
                PhantomBridge.shared.submitInbound(pkt)
            }
        }
    }

    // MARK: - Log ring (served to the app's Logs screen over IPC)

    private func appendLogFrame(_ frame: LogFrame) {
        withStateLock {
            recentLogFrames.append(frame)
            if recentLogFrames.count > 1000 {
                recentLogFrames.removeFirst(recentLogFrames.count - 1000)
            }
        }
    }

    /// Provider-side line next to the core's logs, mirrored to os_log at
    /// default level (persisted on device). `isPublic: false` for lines
    /// that carry the server / relay address.
    private func appendProviderLog(_ msg: String, level: String = "INF", isPublic: Bool = true) {
        appendLogFrame(.structured(level: level, category: "tunnel", msg: msg))
        let type: OSLogType = level == "ERR" ? .error : .default
        if isPublic {
            log.log(level: type, "\(msg, privacy: .public)")
        } else {
            log.log(level: type, "\(msg, privacy: .private)")
        }
    }

    /// Core frames: the ring for the Logs screen; WRN/ERR also to os_log,
    /// public — core messages carry errors and addresses, never the key or
    /// the conn string.
    private func appendCoreLog(_ frame: LogFrame) {
        appendLogFrame(frame)
        let type: OSLogType
        switch frame.level {
        case "ERR": type = .error
        case "WRN": type = .default
        default: return
        }
        let fields = (frame.fields ?? [:]).sorted { $0.key < $1.key }
            .map { " \($0.key)=\($0.value)" }.joined()
        log.log(
            level: type,
            "core \(frame.level, privacy: .public) [\(frame.category ?? "-", privacy: .public)] \(frame.msg, privacy: .public)\(fields, privacy: .public)"
        )
    }

    /// The ring dies with the process, and failures happen while the Logs
    /// screen is closed: keep the last 200 frames in the App Group
    /// (`ext-tail.jsonl`, one `LogFrame` JSON per line, as `logs.jsonl`)
    /// for the app to import.
    private func persistLogTail() {
        let tail = withStateLock { Array(recentLogFrames.suffix(200)) }
        guard !tail.isEmpty,
              let url = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: SharedKeys.appGroup)?
                .appendingPathComponent("ext-tail.jsonl")
        else { return }
        let encoder = JSONEncoder()
        var data = Data()
        for frame in tail {
            guard let line = try? encoder.encode(frame) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Fatal stop notification

    /// The tunnel is gone and won't come back by itself — tell the user why
    /// (the app asked for permission on the first successful connect).
    private func notifyFatalStop(_ reason: String, profileName: String) {
        let override = UserDefaults(suiteName: SharedKeys.appGroup)?.string(forKey: "language_override")
        let language = override.flatMap { $0.isEmpty || $0 == "system" ? nil : $0 }
            ?? Locale.preferredLanguages.first ?? "ru"
        let text = ConnectErrorHumanizer.fatalStop(
            reason,
            profileName: profileName,
            english: language.hasPrefix("en")
        )
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "fatal-stop", content: content, trigger: nil)
        )
    }

    // MARK: - State broadcast

    private func writeStatePayload(_ payload: VpnStatePayload) {
        guard let defaults = UserDefaults(suiteName: "group.com.ghoststream.client") else { return }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: "vpn.state.v1")
            defaults.set(Date().timeIntervalSince1970, forKey: "vpn.state.updatedAt.v1")
        }
        DarwinNotifications.post(DarwinNotifications.stateChanged)

        // The widget and the Control Center toggle read this payload; the app
        // is usually suspended, so the tunnel asks for a reload itself.
        let kindChanged = withStateLock { () -> Bool in
            defer { lastSurfaceKind = payload.kind }
            return lastSurfaceKind != payload.kind
        }
        if kindChanged {
            WidgetCenter.shared.reloadAllTimelines()
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadAllControls()
            }
        }
    }

    private func writeSnapshot(_ frame: StatusFrame) {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.client")?
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
        case .connected, .reconnecting:
            payload = VpnStatePayload(kind: frame.state == .connected ? .connected : .reconnecting,
                                       since: frame.sessionStartedAt,
                                       serverName: frame.sni ?? frame.serverAddr ?? "")
        case .error:
            payload = VpnStatePayload(kind: .error, error: frame.lastError)
        }
        writeStatePayload(payload)
    }

    private func writeDisconnectedSnapshot() {
        // A fatal error stays in the snapshot until the next start so the
        // app can show why the tunnel stopped (revoked, certificate, clock).
        let keepError = withStateLock { () -> Bool in
            statusBroadcastGate.reset()
            guard lastStatusFrame.state != .error else { return true }
            lastStatusFrame = .disconnected
            return false
        }
        if !keepError {
            writeSnapshot(.disconnected)
        }
    }

    private func writeErrorSnapshot(_ message: String) {
        var frame = StatusFrame.disconnected
        frame.state = .error
        frame.lastError = message
        withStateLock {
            statusBroadcastGate.reset()
            lastStatusFrame = frame
        }
        writeSnapshot(frame)
    }

    // MARK: - Helpers

    private enum ProviderError: LocalizedError {
        case missingProtocol
        case missingProfile
        case profileNotFound(String)
        case decodeFailed(String)
        case badTunAddr(String)
        case fatalStop(String)

        var errorDescription: String? {
            switch self {
            case .missingProtocol:         return "protocolConfiguration missing"
            case .missingProfile:          return "providerConfiguration['profile'] or ['profileId'] missing"
            case .profileNotFound(let id): return "Profile not found: \(id)"
            case .decodeFailed(let m):     return "providerConfiguration decode failed: \(m)"
            case .badTunAddr(let s):       return "Invalid tunAddr CIDR: \(s)"
            case .fatalStop(let reason):   return reason
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
