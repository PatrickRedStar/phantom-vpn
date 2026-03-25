import NetworkExtension
import Foundation

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var lastSeq: Int64 = -1

    override func startTunnel(
        options: [String : NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            completionHandler(NSError(domain: "GhostStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad protocol configuration"]))
            return
        }

        let cfg = proto.providerConfiguration ?? [:]
        let serverAddr = cfg["serverAddr"] as? String ?? ""
        let serverName = cfg["serverName"] as? String ?? ""
        let insecure = cfg["insecure"] as? Bool ?? false
        let certPath = cfg["certPath"] as? String ?? ""
        let keyPath = cfg["keyPath"] as? String ?? ""
        let caCertPath = cfg["caCertPath"] as? String ?? ""
        let tunAddr = cfg["tunAddr"] as? String ?? "10.7.0.2/24"
        let dnsServers = cfg["dnsServers"] as? [String] ?? ["1.1.1.1", "8.8.8.8"]
        let splitRouting = cfg["splitRouting"] as? Bool ?? false
        let directCountries = cfg["directCountries"] as? [String] ?? []

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddr)
        settings.mtu = 1350

        let (address, prefix) = parseCIDR(tunAddr)
        let ipv4 = NEIPv4Settings(addresses: [address], subnetMasks: [maskFromPrefix(prefix)])
        if splitRouting {
            ipv4.includedRoutes = []
            ipv4.excludedRoutes = []
            if !directCountries.isEmpty {
                let mergedPath = AppPathsPT.routingMergedPath()
                if let text = try? String(contentsOfFile: mergedPath, encoding: .utf8),
                   !text.isEmpty {
                    ipv4.excludedRoutes = parseRoutesFromCidrs(text)
                }
            }
        } else {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4.excludedRoutes = []
        }
        settings.ipv4Settings = ipv4
        settings.dnsSettings = NEDNSSettings(servers: dnsServers)

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }

            let payload: [String: Any] = [
                "server_addr": serverAddr,
                "server_name": serverName,
                "insecure": insecure,
                "cert_path": certPath,
                "key_path": keyPath,
                "ca_cert_path": caCertPath
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else {
                completionHandler(NSError(domain: "GhostStream", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot build start config"]))
                return
            }

            let tunFd = self.extractTunFd() ?? -1
            let result = json.withCString { ptr in
                phantom_start(Int32(tunFd), ptr)
            }
            if result != 0 {
                completionHandler(NSError(domain: "GhostStream", code: 3, userInfo: [NSLocalizedDescriptionKey: "Rust start failed"]))
                return
            }
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        phantom_stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let op = obj["op"] as? String else {
            completionHandler?(nil)
            return
        }
        switch op {
        case "getStats":
            if let ptr = phantom_get_stats() {
                let s = String(cString: ptr)
                phantom_free_string(ptr)
                completionHandler?(s.data(using: .utf8))
            } else {
                completionHandler?(nil)
            }
        case "getLogs":
            let since = (obj["sinceSeq"] as? NSNumber)?.int64Value ?? -1
            if let ptr = phantom_get_logs(since) {
                let s = String(cString: ptr)
                phantom_free_string(ptr)
                completionHandler?(s.data(using: .utf8))
            } else {
                completionHandler?(Data("[]".utf8))
            }
        case "setLogLevel":
            let level = (obj["level"] as? String ?? "info").lowercased()
            level.withCString { ptr in
                phantom_set_log_level(ptr)
            }
            completionHandler?(Data("{}".utf8))
        default:
            completionHandler?(nil)
        }
    }

    private func parseCIDR(_ cidr: String) -> (String, Int) {
        let parts = cidr.split(separator: "/")
        let ip = parts.first.map(String.init) ?? "10.7.0.2"
        let prefix = parts.count == 2 ? (Int(parts[1]) ?? 24) : 24
        return (ip, max(0, min(32, prefix)))
    }

    private func maskFromPrefix(_ prefix: Int) -> String {
        guard prefix > 0 else { return "0.0.0.0" }
        let mask = UInt32.max << (32 - UInt32(prefix))
        return [
            String((mask >> 24) & 255),
            String((mask >> 16) & 255),
            String((mask >> 8) & 255),
            String(mask & 255)
        ].joined(separator: ".")
    }

    private func parseRoutesFromCidrs(_ text: String) -> [NEIPv4Route] {
        text.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.hasPrefix("#") || value.contains(":") { return nil }
            let parts = value.split(separator: "/")
            guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return nil }
            return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: maskFromPrefix(prefix))
        }
    }

    private func extractTunFd() -> Int32? {
        // Best-effort fallback; production iOS path should pass packetFlow FD via supported API.
        if let value = (packetFlow as NSObject).value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            return value
        }
        return nil
    }
}

private enum AppPathsPT {
    static let appGroupId = "group.com.ghoststream.vpn"

    static func sharedContainerURL() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            return url
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func routingMergedPath() -> String {
        sharedContainerURL()
            .appendingPathComponent("routing_rules", isDirectory: true)
            .appendingPathComponent("selected_merged.txt")
            .path
    }
}
