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
                self.writeStatePayload(.init(kind: .error, error: error.localizedDescription))
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
            writeStatePayload(VpnStatePayload(kind: .disconnected))
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

        case .updateRoutePolicy:
            let response = TunnelIpcBridge.Response.ok
            completionHandler?(try? JSONEncoder().encode(response))

        case .disconnect:
            outboundTask?.cancel()
            Task {
                await PhantomBridge.shared.stop()
                writeStatePayload(VpnStatePayload(kind: .disconnected))
                let response = TunnelIpcBridge.Response.ok
                completionHandler?(try? JSONEncoder().encode(response))
            }
        }
    }

    // MARK: - Start implementation

    private func startTunnelAsync(completionHandler: @escaping (Error?) -> Void) async throws {
        writeStatePayload(VpnStatePayload(kind: .connecting))

        let profile = try loadProfile()

        // Build NEPacketTunnelNetworkSettings.
        let (tunIp, subnetMask) = try parseCidr(profile.tunAddr)
        let serverHost = hostPart(of: profile.serverAddr)

        let networkSettings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverHost)
        networkSettings.mtu = NSNumber(value: 1350)

        let ipv4 = NEIPv4Settings(addresses: [tunIp], subnetMasks: [subnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = []
        networkSettings.ipv4Settings = ipv4

        // IPv6 killswitch
        let ipv6 = NEIPv6Settings(addresses: [], networkPrefixLengths: [])
        ipv6.excludedRoutes = [NEIPv6Route.default()]
        networkSettings.ipv6Settings = ipv6

        let dnsServers = profile.dnsServers ?? ["1.1.1.1", "8.8.8.8"]
        let dns = NEDNSSettings(servers: dnsServers)
        dns.matchDomains = [""]
        networkSettings.dnsSettings = dns

        try await setTunnelNetworkSettings(networkSettings)

        let settings = TunnelSettings()
        var didCallCompletion = false

        // Start the Rust tunnel via PhantomKit actor bridge.
        do {
            try await PhantomBridge.shared.start(
                profile: profile,
                settings: settings,
                onStatus: { [weak self] frame in
                    guard let self else { return }
                    self.lastStatusFrame = frame

                    // Write snapshot for the main app to read
                    self.writeSnapshot(frame)

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

    // MARK: - Profile loading

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
                await PhantomBridge.shared.submitInbound(pkt)
            }
        }
    }

    // MARK: - State broadcast

    private func writeStatePayload(_ payload: VpnStatePayload) {
        guard let defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn") else { return }
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: "vpn.state.v1")
        }
        DarwinNotifications.post(DarwinNotifications.stateChanged)
    }

    private func writeSnapshot(_ frame: StatusFrame) {
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.vpn")?
            .appendingPathComponent("snapshot.json"),
              let data = try? JSONEncoder().encode(frame)
        else { return }
        try? data.write(to: url, options: .atomic)

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
}
