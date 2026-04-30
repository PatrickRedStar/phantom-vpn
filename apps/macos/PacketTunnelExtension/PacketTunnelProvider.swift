//
//  PacketTunnelProvider.swift
//  GhostStream macOS — system extension
//
//  Adapted from apps/ios/PacketTunnelProvider/PacketTunnelProvider.swift.
//  Same loadProfile / setTunnelNetworkSettings / outboundLoop pattern;
//  on macOS the host bundle is sibling to the system extension, so the
//  shared App Group container path is identical.
//

import Foundation
import Network
import NetworkExtension
import PhantomKit
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.ghoststream.vpn.tunnel", category: "tunnel")
    private var outboundTask: Task<Void, Never>?
    private var providerTelemetryTask: Task<Void, Never>?
    private var routeSettingsTask: Task<Void, Never>?

    private var lastStatusFrame: StatusFrame = .disconnected
    private var recentLogFrames: [LogFrame] = []
    private let snapshotPayloadKey = "vpn.statusFrame.v1"
    private let snapshotUpdatedAtKey = "vpn.statusFrame.updatedAt"
    private let telemetryLock = NSLock()
    private var telemetryStartedAt: Date?
    private var telemetryProfile: VpnProfile?
    private var telemetrySettings: TunnelSettings?
    private var activeProfile: VpnProfile?
    private var activeSettings: TunnelSettings?
    private var telemetryRxBytes: UInt64 = 0
    private var telemetryTxBytes: UInt64 = 0
    private var telemetryLastRxBytes: UInt64 = 0
    private var telemetryLastTxBytes: UInt64 = 0
    private var telemetryLastSampleAt = Date()

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
        providerTelemetryTask?.cancel()
        providerTelemetryTask = nil
        routeSettingsTask?.cancel()
        routeSettingsTask = nil
        activeProfile = nil
        activeSettings = nil
        appendProviderLog(level: "INF", message: "stopTunnel reason=\(reason.rawValue)")

        Task {
            await PhantomBridge.shared.stop()
            writeDisconnectedSnapshot()
            completionHandler()
        }
    }

    // MARK: - IPC

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let message = decodeIpcMessage(messageData) else {
            appendProviderLog(level: "WRN", message: "unable to decode app IPC message")
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
                    self.appendProviderLog(level: "ERR", message: "route policy update failed: \(error.localizedDescription)")
                    let response = TunnelIpcBridge.Response.error(error.localizedDescription)
                    completionHandler?(try? JSONEncoder().encode(response))
                }
            }

        case .disconnect:
            outboundTask?.cancel()
            providerTelemetryTask?.cancel()
            providerTelemetryTask = nil
            routeSettingsTask?.cancel()
            routeSettingsTask = nil
            activeProfile = nil
            activeSettings = nil
            appendProviderLog(level: "INF", message: "disconnect requested by host app")
            Task {
                await PhantomBridge.shared.stop()
                writeDisconnectedSnapshot()
                let response = TunnelIpcBridge.Response.ok
                completionHandler?(try? JSONEncoder().encode(response))
            }
        }
    }

    private func decodeIpcMessage(_ data: Data) -> TunnelIpcBridge.Message? {
        if let message = try? JSONDecoder().decode(TunnelIpcBridge.Message.self, from: data) {
            return message
        }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["getStatus"] != nil { return .getStatus }
            if object["getCurrentProfile"] != nil { return .getCurrentProfile }
            if object["disconnect"] != nil { return .disconnect }
            if let payload = object["subscribeLogs"] as? [String: Any] {
                let since = (payload["sinceMs"] as? NSNumber)?.uint64Value
                    ?? (payload["since_ms"] as? NSNumber)?.uint64Value
                    ?? 0
                return .subscribeLogs(sinceMs: since)
            }
            if let payload = object["updateRoutePolicy"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let snapshot = try? JSONDecoder().decode(RoutePolicySnapshot.self, from: data) {
                return .updateRoutePolicy(snapshot)
            }
        }

        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return nil }

        switch raw {
        case "getstatus", "get_status", "status":
            return .getStatus
        case "getcurrentprofile", "get_current_profile", "profile":
            return .getCurrentProfile
        case "disconnect", "stop":
            return .disconnect
        default:
            return nil
        }
    }

    // MARK: - Start

    private func startTunnelAsync(completionHandler: @escaping (Error?) -> Void) async throws {
        writeStatePayload(VpnStatePayload(kind: .connecting))

        let profile = try loadProfile()
        let settings = loadSettings()
        activeProfile = profile
        activeSettings = settings
        resetProviderTelemetry(profile: profile, settings: settings)
        appendProviderLog(level: "INF", message: "starting tunnel profile=\(profile.name)")
        publishProviderStatusFrame(state: .connecting)

        let networkSettings = try makeNetworkSettings(profile: profile, settings: settings)

        try await setTunnelNetworkSettings(networkSettings)
        appendProviderLog(level: "INF", message: "network settings applied tun=\(profile.tunAddr)")
        let runtimeProfile = profileForRuntime(profile: profile, settings: settings)

        var didCallCompletion = false

        do {
            try await PhantomBridge.shared.start(
                profile: runtimeProfile,
                settings: settings,
                onStatus: { [weak self] frame in
                    guard let self else { return }
                    self.lastStatusFrame = frame
                    self.writeSnapshot(frame)
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
                    self.addRxBytes(UInt64(data.count))
                    self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: AF_INET)])
                }
            )
        } catch {
            await PhantomBridge.shared.stop()
            appendProviderLog(level: "ERR", message: "runtime start failed: \(error.localizedDescription)")
            throw error
        }

        appendProviderLog(level: "OK", message: "runtime started")
        publishProviderStatusFrame(state: .connected)
        startProviderTelemetryLoop()

        if !didCallCompletion {
            didCallCompletion = true
            completionHandler(nil)
        }

        outboundTask = Task.detached { [weak self] in
            await self?.outboundLoop()
        }
    }

    // MARK: - Profile loading

    private func loadProfile() throws -> VpnProfile {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            throw ProviderError.missingProtocol
        }

        if let profileData = proto.providerConfiguration?["profile"] as? Data {
            do {
                let profile = try JSONDecoder().decode(VpnProfile.self, from: profileData)
                log.info("loaded embedded provider profile id=\(profile.id, privacy: .public)")
                return profile
            } catch {
                throw ProviderError.decodeFailed(error.localizedDescription)
            }
        }

        if let profileId = proto.providerConfiguration?["profileId"] as? String {
            log.info("loading legacy provider profileId=\(profileId, privacy: .public)")
            guard let profile = resolveProfile(id: profileId) else {
                throw ProviderError.profileNotFound(profileId)
            }
            return profile
        }

        throw ProviderError.missingProfile
    }

    private func loadSettings() -> TunnelSettings {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let settingsData = proto.providerConfiguration?["settings"] as? Data,
              let settings = try? JSONDecoder().decode(TunnelSettings.self, from: settingsData)
        else {
            return TunnelSettings()
        }
        return settings
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

        let ipv6 = NEIPv6Settings(addresses: [], networkPrefixLengths: [])
        if settings.ipv6Killswitch {
            ipv6.includedRoutes = [NEIPv6Route.default()]
        } else {
            ipv6.excludedRoutes = [NEIPv6Route.default()]
        }
        networkSettings.ipv6Settings = ipv6

        let dnsServers = profile.dnsServers ?? ["1.1.1.1", "8.8.8.8"]
        let dns = NEDNSSettings(servers: dnsServers)
        if settings.dnsLeakProtection && shouldForceDnsMatchDomains(settings: settings) {
            dns.matchDomains = [""]
        }
        networkSettings.dnsSettings = dns

        return networkSettings
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
                "split routing has directCountries=\(directCountries.joined(separator: ","), privacy: .public), but no country CIDR bundle is available; applying conservative public IPv4 route set"
            )
        }

        let directCidrs = directCidrsForRouteComputation(profile: profile, settings: settings)
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

    private func directCidrsForRouteComputation(
        profile: VpnProfile,
        settings: TunnelSettings
    ) -> [String] {
        var cidrs = settings.routePolicy?.serverDirectCidrs ?? []
        if settings.routingMode != .global {
            cidrs.append(contentsOf: settings.manualDirectCidrs)
        }
        if settings.routingMode == .layeredAuto {
            cidrs.append(contentsOf: settings.routePolicy?.detectedUpstreamCidrs ?? [])
            cidrs.append(contentsOf: settings.routePolicy?.manualDirectCidrs ?? [])
        }

        let normalized = RoutePolicySnapshot.normalizedCidrs(from: cidrs.joined(separator: "\n")).valid
        if settings.routingMode == .layeredAuto {
            appendProviderLog(
                level: "INF",
                message: "layered routing directCidrs=\(normalized.count) upstream=\(settings.routePolicy?.detectedUpstreamCidrs.count ?? 0) manual=\(settings.manualDirectCidrs.count)"
            )
        }
        return normalized
    }

    private func profileForRuntime(profile: VpnProfile, settings: TunnelSettings) -> VpnProfile {
        guard let endpoint = resolvedServerEndpoint(profile: profile, settings: settings) else {
            return profile
        }

        var runtimeProfile = profile
        runtimeProfile.serverAddr = endpoint
        if let connString = profile.connString,
           let rewritten = rewriteConnStringAuthority(connString, authority: endpoint) {
            runtimeProfile.connString = rewritten
            appendProviderLog(level: "INF", message: "runtime server endpoint pinned to \(endpoint)")
        }
        return runtimeProfile
    }

    private func resolvedServerEndpoint(profile: VpnProfile, settings: TunnelSettings) -> String? {
        guard let serverCidr = settings.routePolicy?.serverDirectCidrs.first,
              let serverIp = serverCidr.split(separator: "/", maxSplits: 1).first,
              IPv4Address(String(serverIp)) != nil
        else { return nil }

        let currentHost = hostPart(of: profile.serverAddr)
        guard IPv4Address(currentHost) == nil else { return nil }

        let port = portPart(of: profile.connString)
            ?? portPart(of: profile.serverAddr)
            ?? "443"
        return "\(serverIp):\(port)"
    }

    private func rewriteConnStringAuthority(_ connString: String, authority: String) -> String? {
        guard connString.hasPrefix("ghs://"),
              let at = connString.firstIndex(of: "@")
        else { return nil }

        let authorityStart = connString.index(after: at)
        guard let queryStart = connString[authorityStart...].firstIndex(of: "?") else {
            return nil
        }

        return String(connString[..<authorityStart])
            + authority
            + String(connString[queryStart...])
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

    private func updateRoutePolicy(_ snapshot: RoutePolicySnapshot) async throws {
        guard var settings = activeSettings, let profile = activeProfile else {
            throw ProviderError.missingProfile
        }
        settings.routingMode = snapshot.mode
        settings.manualDirectCidrs = snapshot.manualDirectCidrs
        settings.preserveScopedDns = snapshot.preserveScopedDns
        settings.routePolicy = snapshot
        activeSettings = settings

        routeSettingsTask?.cancel()
        let networkSettings = try makeNetworkSettings(profile: profile, settings: settings)
        try await setTunnelNetworkSettings(networkSettings)
        appendProviderLog(
            level: "OK",
            message: "route policy applied hash=\(snapshot.routeHash) upstreamRoutes=\(snapshot.detectedUpstreamCidrs.count)"
        )
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
                addTxBytes(UInt64(pkt.count))
                await PhantomBridge.shared.submitInbound(pkt)
            }
        }
    }

    // MARK: - State broadcast

    private func writeStatePayload(_ payload: VpnStatePayload) {
        guard let defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn") else { return }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: "vpn.state.v1")
            defaults.synchronize()
        }
        DarwinNotifications.post(DarwinNotifications.stateChanged)
    }

    private func writeSnapshot(_ frame: StatusFrame) {
        guard let data = try? JSONEncoder().encode(frame) else { return }

        if let defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn") {
            defaults.set(data, forKey: snapshotPayloadKey)
            defaults.set(Date().timeIntervalSince1970, forKey: snapshotUpdatedAtKey)
            defaults.synchronize()
        }

        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.vpn")?
            .appendingPathComponent("snapshot.json")
        {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("snapshot write failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.error("snapshot container unavailable")
        }

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

    private func writeErrorSnapshot(_ message: String) {
        appendProviderLog(level: "ERR", message: message)
        let frame = StatusFrame(
            state: .error,
            sessionSecs: 0,
            bytesRx: 0,
            bytesTx: 0,
            rateRxBps: 0,
            rateTxBps: 0,
            nStreams: 0,
            streamsUp: 0,
            streamActivity: Array(repeating: 0, count: 16),
            rttMs: nil,
            tunAddr: nil,
            serverAddr: nil,
            sni: nil,
            lastError: message,
            reconnectAttempt: nil,
            reconnectNextDelaySecs: nil
        )
        lastStatusFrame = frame
        writeSnapshot(frame)
    }

    private func writeDisconnectedSnapshot() {
        appendProviderLog(level: "INF", message: "tunnel disconnected")
        lastStatusFrame = .disconnected
        writeSnapshot(.disconnected)
    }

    private func resetProviderTelemetry(profile: VpnProfile, settings: TunnelSettings) {
        telemetryLock.lock()
        telemetryStartedAt = Date()
        telemetryProfile = profile
        telemetrySettings = settings
        telemetryRxBytes = 0
        telemetryTxBytes = 0
        telemetryLastRxBytes = 0
        telemetryLastTxBytes = 0
        telemetryLastSampleAt = Date()
        telemetryLock.unlock()
    }

    private func addRxBytes(_ count: UInt64) {
        telemetryLock.lock()
        telemetryRxBytes = telemetryRxBytes &+ count
        telemetryLock.unlock()
    }

    private func addTxBytes(_ count: UInt64) {
        telemetryLock.lock()
        telemetryTxBytes = telemetryTxBytes &+ count
        telemetryLock.unlock()
    }

    private func startProviderTelemetryLoop() {
        providerTelemetryTask?.cancel()
        providerTelemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                self?.publishProviderStatusFrame(state: .connected)
            }
        }
    }

    private func publishProviderStatusFrame(state: ConnState) {
        let frame = makeProviderStatusFrame(state: state)
        lastStatusFrame = frame
        writeSnapshot(frame)
    }

    private func makeProviderStatusFrame(state: ConnState) -> StatusFrame {
        telemetryLock.lock()
        let now = Date()
        let startedAt = telemetryStartedAt ?? now
        let profile = telemetryProfile
        let settings = telemetrySettings
        let rxBytes = telemetryRxBytes
        let txBytes = telemetryTxBytes
        let dt = max(0.001, now.timeIntervalSince(telemetryLastSampleAt))
        let rateRx = Double(rxBytes >= telemetryLastRxBytes ? rxBytes - telemetryLastRxBytes : 0) / dt
        let rateTx = Double(txBytes >= telemetryLastTxBytes ? txBytes - telemetryLastTxBytes : 0) / dt
        telemetryLastRxBytes = rxBytes
        telemetryLastTxBytes = txBytes
        telemetryLastSampleAt = now
        telemetryLock.unlock()

        let live = state == .connected
        let streamCount = live ? UInt8(max(1, min(16, settings?.streams ?? 1))) : 0
        let activityLevel: Float = (rateRx + rateTx) > 0 ? 1.0 : (live ? 0.12 : 0)
        var streamActivity = Array(repeating: Float(0), count: 16)
        if streamCount > 0 {
            for idx in 0..<Int(streamCount) {
                streamActivity[idx] = activityLevel
            }
        }

        return StatusFrame(
            state: state,
            sessionSecs: UInt64(max(0, now.timeIntervalSince(startedAt))),
            bytesRx: rxBytes,
            bytesTx: txBytes,
            rateRxBps: rateRx,
            rateTxBps: rateTx,
            nStreams: streamCount,
            streamsUp: streamCount,
            streamActivity: streamActivity,
            rttMs: nil,
            tunAddr: profile?.tunAddr,
            serverAddr: profile?.serverAddr,
            sni: profile?.serverName,
            lastError: nil,
            reconnectAttempt: nil,
            reconnectNextDelaySecs: nil
        )
    }

    private func appendProviderLog(level: String, message: String) {
        let frame = LogFrame(
            tsUnixMs: UInt64(Date().timeIntervalSince1970 * 1000),
            level: level,
            msg: message
        )
        recentLogFrames.append(frame)
        if recentLogFrames.count > 1000 {
            recentLogFrames.removeFirst(recentLogFrames.count - 1000)
        }
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

    private func mask(forIPv4Prefix prefix: UInt8) -> String? {
        guard prefix <= 32 else { return nil }
        guard prefix > 0 else { return "0.0.0.0" }
        let mask = UInt32.max << (32 - UInt32(prefix))
        let octets = [(mask >> 24) & 0xFF, (mask >> 16) & 0xFF, (mask >> 8) & 0xFF, mask & 0xFF]
        return octets.map { String($0) }.joined(separator: ".")
    }

    private func hostPart(of addr: String) -> String {
        if let lastColon = addr.lastIndex(of: ":"),
           addr.firstIndex(of: ":") == lastColon {
            return String(addr[..<lastColon])
        }
        return addr
    }

    private func portPart(of addr: String?) -> String? {
        guard let addr else { return nil }
        let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("["),
           let close = trimmed.firstIndex(of: "]") {
            let afterClose = trimmed.index(after: close)
            guard afterClose < trimmed.endIndex,
                  trimmed[afterClose] == ":"
            else { return nil }
            let portStart = trimmed.index(after: afterClose)
            guard portStart < trimmed.endIndex else { return nil }
            let port = String(trimmed[portStart...])
            return UInt16(port) == nil ? nil : port
        }

        guard let colon = trimmed.lastIndex(of: ":"),
              trimmed[..<colon].firstIndex(of: ":") == nil
        else { return nil }

        let port = String(trimmed[trimmed.index(after: colon)...])
        return UInt16(port) == nil ? nil : port
    }

    private func tunnelRemoteAddress(for addr: String) -> String {
        let host = hostPart(of: addr)
        if IPv4Address(host) != nil || IPv6Address(host) != nil {
            return host
        }
        return "127.0.0.1"
    }
}
