// PacketTunnelProvider — NEPacketTunnelProvider entry point for GhostStream.
//
// Architecture (Phase 6):
//   • Reads profileId from providerConfiguration (set by VpnTunnelController).
//   • Loads the full VpnProfile from shared App Group UserDefaults via
//     ProfilesStore; PEM secrets hydrated from the shared Keychain.
//   • Configures NEPacketTunnelNetworkSettings with IPv4 full-tunnel +
//     IPv6 killswitch (excludes default IPv6 route to prevent leaks).
//   • Registers a Rust inbound callback, starts the Rust tunnel, pumps
//     outbound packets from packetFlow to Rust.
//   • Writes StatusFrame snapshots to the App Group container
//     (snapshot.json) so VpnStateManager can observe them via UserDefaults
//     change notifications — no Darwin notification needed for status.
//   • Handles handleAppMessage for IPC with the main app (get status,
//     subscribe logs, disconnect).

import Foundation
import NetworkExtension
import os.log

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.ghoststream.vpn.PacketTunnel", category: "tunnel")

    private var outboundTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var didPostConnected = false

    // MARK: - In-process state

    private var lastStatusPayload = VpnStatePayload(kind: .disconnected)
    private var recentLogLines: [AppLogEntry] = []

    // MARK: - Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                try await self.startTunnelAsync()
                completionHandler(nil)
            } catch {
                self.log.error("startTunnel failed: \(error.localizedDescription, privacy: .public)")
                self.broadcastState(VpnStatePayload(kind: .error, error: error.localizedDescription))
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
        statsTask?.cancel()
        outboundTask = nil
        statsTask = nil

        PhantomBridge.stop()
        PhantomBridge.clearInboundCallback()

        broadcastState(VpnStatePayload(kind: .disconnected))
        completionHandler()
    }

    // MARK: - IPC (handleAppMessage)

    /// Simple IPC message tag (must match the main app's VpnTunnelController call sites).
    private enum IpcCommand: String, Decodable {
        case getStatus
        case getLogs
        case disconnect
    }

    private struct IpcRequest: Decodable {
        let cmd: IpcCommand
        let sinceMs: UInt64?
    }

    private struct IpcResponse: Encodable {
        let ok: Bool
        let status: VpnStatePayload?
        let logs: [AppLogEntry]?
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let request: IpcRequest
        do {
            request = try JSONDecoder().decode(IpcRequest.self, from: messageData)
        } catch {
            completionHandler?(nil)
            return
        }

        switch request.cmd {
        case .getStatus:
            let response = IpcResponse(ok: true, status: lastStatusPayload, logs: nil)
            completionHandler?(try? JSONEncoder().encode(response))

        case .getLogs:
            let sinceMs = request.sinceMs ?? 0
            let filtered = recentLogLines.filter { $0.tsMs > sinceMs }
            let response = IpcResponse(ok: true, status: nil, logs: filtered)
            completionHandler?(try? JSONEncoder().encode(response))

        case .disconnect:
            outboundTask?.cancel()
            statsTask?.cancel()
            PhantomBridge.stop()
            PhantomBridge.clearInboundCallback()
            broadcastState(VpnStatePayload(kind: .disconnected))
            let response = IpcResponse(ok: true, status: nil, logs: nil)
            completionHandler?(try? JSONEncoder().encode(response))
        }
    }

    // MARK: - Start implementation

    private func startTunnelAsync() async throws {
        broadcastState(VpnStatePayload(kind: .connecting))

        let profile = try loadProfile()

        // Build NEPacketTunnelNetworkSettings.
        let (tunIp, subnetMask) = try parseCidr(profile.tunAddr)
        let serverHost = hostPart(of: profile.serverAddr)

        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverHost)
        networkSettings.mtu = NSNumber(value: 1350)

        // IPv4: route all traffic through the tunnel.
        let ipv4 = NEIPv4Settings(addresses: [tunIp], subnetMasks: [subnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = []
        networkSettings.ipv4Settings = ipv4

        // IPv6 killswitch: exclude the default IPv6 route to prevent leaks
        // while the tunnel is active. This matches the approach recommended in
        // Apple's NEPacketTunnelNetworkSettings docs.
        let ipv6 = NEIPv6Settings(addresses: [], networkPrefixLengths: [])
        ipv6.excludedRoutes = [NEIPv6Route.default()]
        networkSettings.ipv6Settings = ipv6

        // DNS — prefer profile-level servers; fall back to Cloudflare/Google.
        let dnsServers = profile.dnsServers ?? ["1.1.1.1", "8.8.8.8"]
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        networkSettings.dnsSettings = dns

        try await setTunnelNetworkSettings(networkSettings)

        // Register the inbound callback — Rust pushes decapsulated IP packets
        // here; we forward them to packetFlow.
        PhantomBridge.setInboundCallback { [weak self] data in
            guard let self else { return }
            self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: AF_INET)])
        }

        // Start the Rust tunnel.
        let startConfig = StartConfig(
            serverAddr: profile.serverAddr,
            serverName: profile.serverName,
            insecure: profile.insecure,
            certPem: profile.certPem ?? "",
            keyPem: profile.keyPem ?? "",
            tunAddr: profile.tunAddr,
            tunMtu: 1350
        )
        do {
            try PhantomBridge.start(startConfig)
        } catch {
            PhantomBridge.clearInboundCallback()
            throw error
        }

        // Outbound loop: drain packetFlow → Rust.
        outboundTask = Task.detached { [weak self] in
            await self?.outboundLoop()
        }

        // Stats loop: flip state to .connected once Rust reports live tunnel,
        // then keep writing snapshots periodically.
        let serverNameCopy = profile.serverName
        statsTask = Task.detached { [weak self] in
            await self?.statsLoop(serverName: serverNameCopy)
        }
    }

    // MARK: - Profile loading

    private func loadProfile() throws -> VpnProfile {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            throw ProviderError.missingProtocol
        }

        // Phase 6+: prefer profileId-based lookup.
        if let profileId = proto.providerConfiguration?["profileId"] as? String {
            guard let profile = resolveProfile(id: profileId) else {
                throw ProviderError.profileNotFound(profileId)
            }
            return profile
        }

        // Fallback: legacy full-profile JSON blob (pre-Phase-6 VpnTunnelController).
        guard let profileData = proto.providerConfiguration?["profile"] as? Data else {
            throw ProviderError.missingProfile
        }
        do {
            return try JSONDecoder().decode(VpnProfile.self, from: profileData)
        } catch {
            throw ProviderError.decodeFailed(error.localizedDescription)
        }
    }

    /// Resolves a VpnProfile by id from App Group UserDefaults, with PEM
    /// secrets hydrated from the shared Keychain access group.
    private func resolveProfile(id: String) -> VpnProfile? {
        let defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")
        guard
            let data = defaults?.data(forKey: "profiles.json"),
            let profiles = try? JSONDecoder().decode([VpnProfile].self, from: data),
            var profile = profiles.first(where: { $0.id == id })
        else { return nil }

        // Hydrate PEM secrets from the shared Keychain.
        profile.certPem = Keychain.get("profile.\(id).cert")
        profile.keyPem  = Keychain.get("profile.\(id).key")
        return profile
    }

    // MARK: - Packet loops

    private func outboundLoop() async {
        while !Task.isCancelled {
            let packets: [Data] = await withCheckedContinuation { cont in
                self.packetFlow.readPackets { packets, _ in
                    cont.resume(returning: packets)
                }
            }
            if Task.isCancelled { break }
            for pkt in packets {
                PhantomBridge.submitOutbound(pkt)
            }
        }
    }

    private func statsLoop(serverName: String) async {
        while !Task.isCancelled {
            if let stats = PhantomBridge.stats(), stats.connected {
                if !didPostConnected {
                    didPostConnected = true
                    broadcastState(VpnStatePayload(
                        kind: .connected,
                        since: Date().timeIntervalSince1970,
                        serverName: serverName
                    ))
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - State broadcast

    /// Writes the payload to App Group UserDefaults and posts a Darwin
    /// notification so the main app's VpnStateManager can pick it up.
    /// Note: `writeVpnState` (SharedState.swift) already posts the Darwin
    /// notification — no need to post it again here.
    private func broadcastState(_ payload: VpnStatePayload) {
        lastStatusPayload = payload
        writeVpnState(payload)
    }

    // MARK: - Log capture

    struct AppLogEntry: Codable {
        let tsMs: UInt64
        let level: String
        let msg: String
    }

    private func appendLog(level: String, msg: String) {
        let entry = AppLogEntry(
            tsMs: UInt64(Date().timeIntervalSince1970 * 1000),
            level: level,
            msg: msg
        )
        recentLogLines.append(entry)
        if recentLogLines.count > 1000 {
            recentLogLines.removeFirst(recentLogLines.count - 1000)
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

    /// Parses "10.7.0.2/24" into ("10.7.0.2", "255.255.255.0").
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

    /// Extracts the host part of "host:port".
    private func hostPart(of addr: String) -> String {
        if let lastColon = addr.lastIndex(of: ":"),
           addr.firstIndex(of: ":") == lastColon {
            return String(addr[..<lastColon])
        }
        return addr
    }
}
