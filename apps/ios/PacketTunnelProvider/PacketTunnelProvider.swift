// PacketTunnelProvider — NEPacketTunnelProvider entry point for
// GhostStream. Reads the VPN profile from providerConfiguration, configures
// NEPacketTunnelNetworkSettings, registers the Rust inbound callback,
// starts the Rust tunnel, and pumps packets between packetFlow and Rust.

import Foundation
import NetworkExtension
import os.log

/// NEPacketTunnelProvider subclass wiring iOS packet-flow I/O to the Rust
/// `phantom_*` library.
final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.ghoststream.vpn.PacketTunnel", category: "tunnel")

    private var readTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var didPostConnected = false

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
                writeVpnState(VpnStatePayload(kind: .error, error: error.localizedDescription))
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        readTask?.cancel()
        statsTask?.cancel()
        readTask = nil
        statsTask = nil

        PhantomBridge.stop()
        PhantomBridge.clearInboundCallback()

        writeVpnState(VpnStatePayload(kind: .disconnected))
        completionHandler()
    }

    // MARK: - Start implementation

    private func startTunnelAsync() async throws {
        writeVpnState(VpnStatePayload(kind: .connecting))

        let (profile, prefs) = try decodeProviderConfiguration()

        // Build NEPacketTunnelNetworkSettings.
        let (tunIp, subnetMask) = try parseCidr(profile.tunAddr)
        let serverHost = hostPart(of: profile.serverAddr)

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverHost)
        settings.mtu = NSNumber(value: 1350)

        let ipv4 = NEIPv4Settings(addresses: [tunIp], subnetMasks: [subnetMask])
        // TODO(split-routing): when splitRouting is enabled, replace
        // [NEIPv4Route.default()] with routes derived from
        // PhantomBridge.computeVpnRoutes(directCidrs:). v1 ships
        // full-tunnel only.
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: prefs.dnsServers ?? ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        try await setTunnelNetworkSettings(settings)

        // Register inbound callback — Rust pushes decapsulated IP packets
        // here, we forward them to packetFlow.
        PhantomBridge.setInboundCallback { [weak self] data in
            guard let self else { return }
            self.packetFlow.writePackets(
                [data],
                withProtocols: [NSNumber(value: AF_INET)]
            )
        }

        // Start Rust tunnel.
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

        // Spawn the outbound read loop.
        readTask = Task.detached { [weak self] in
            await self?.readLoop()
        }

        // Spawn a stats-polling task that flips us to `.connected` once
        // the Rust side reports a live tunnel.
        let serverNameCopy = profile.serverName
        statsTask = Task.detached { [weak self] in
            await self?.statsLoop(serverName: serverNameCopy)
        }
    }

    // MARK: - Read loop

    private func readLoop() async {
        while !Task.isCancelled {
            let packets: [Data] = await withCheckedContinuation { cont in
                self.packetFlow.readPackets { packets, _ in
                    cont.resume(returning: packets)
                }
            }
            if Task.isCancelled { break }
            for packet in packets {
                PhantomBridge.submitOutbound(packet)
            }
        }
    }

    // MARK: - Stats loop

    private func statsLoop(serverName: String) async {
        while !Task.isCancelled {
            if let s = PhantomBridge.stats(), s.connected, !didPostConnected {
                didPostConnected = true
                writeVpnState(VpnStatePayload(
                    kind: .connected,
                    since: Date().timeIntervalSince1970,
                    serverName: serverName
                ))
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Config decoding

    private struct ProfileDTO: Decodable {
        let serverAddr: String
        let serverName: String
        let insecure: Bool
        let certPem: String?
        let keyPem: String?
        let tunAddr: String
        let dnsServers: [String]?
        let splitRouting: Bool?
    }

    private struct PrefsDTO: Decodable {
        let dnsServers: [String]?
        let splitRouting: Bool?
    }

    private enum ProviderConfigError: LocalizedError {
        case missingProtocol
        case missingProfile
        case decodeFailed(String)
        case badTunAddr(String)

        var errorDescription: String? {
            switch self {
            case .missingProtocol:      return "protocolConfiguration missing"
            case .missingProfile:       return "providerConfiguration['profile'] missing"
            case .decodeFailed(let m):  return "providerConfiguration decode failed: \(m)"
            case .badTunAddr(let s):    return "Invalid tunAddr CIDR: \(s)"
            }
        }
    }

    private func decodeProviderConfiguration() throws -> (ProfileDTO, PrefsDTO) {
        guard let proto = self.protocolConfiguration as? NETunnelProviderProtocol else {
            throw ProviderConfigError.missingProtocol
        }
        guard let cfg = proto.providerConfiguration else {
            throw ProviderConfigError.missingProfile
        }
        guard let profileData = cfg["profile"] as? Data else {
            throw ProviderConfigError.missingProfile
        }
        let profile: ProfileDTO
        do {
            profile = try JSONDecoder().decode(ProfileDTO.self, from: profileData)
        } catch {
            throw ProviderConfigError.decodeFailed(error.localizedDescription)
        }

        let prefs: PrefsDTO
        if let prefsData = cfg["prefs"] as? Data {
            prefs = (try? JSONDecoder().decode(PrefsDTO.self, from: prefsData))
                ?? PrefsDTO(dnsServers: nil, splitRouting: nil)
        } else {
            prefs = PrefsDTO(dnsServers: nil, splitRouting: nil)
        }
        return (profile, prefs)
    }

    // MARK: - Helpers

    /// Parses "10.7.0.2/24" into ("10.7.0.2", "255.255.255.0").
    private func parseCidr(_ cidr: String) throws -> (String, String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 32
        else {
            throw ProviderConfigError.badTunAddr(cidr)
        }
        let ip = String(parts[0])
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        let octets = [
            (mask >> 24) & 0xFF,
            (mask >> 16) & 0xFF,
            (mask >> 8) & 0xFF,
            mask & 0xFF,
        ]
        let maskStr = octets.map { String($0) }.joined(separator: ".")
        return (ip, maskStr)
    }

    /// Extracts the host part of "host:port" (e.g. "89.110.109.128:8443"
    /// → "89.110.109.128"). Leaves IPv6-bracketed hosts unchanged.
    private func hostPart(of addr: String) -> String {
        if let lastColon = addr.lastIndex(of: ":"),
           addr.firstIndex(of: ":") == lastColon {
            return String(addr[..<lastColon])
        }
        return addr
    }
}
