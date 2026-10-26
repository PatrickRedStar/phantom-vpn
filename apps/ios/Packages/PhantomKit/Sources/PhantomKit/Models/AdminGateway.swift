import Foundation

public enum AdminGateway {
    public static let fallbackHost = "10.7.0.1"

    public static func host(forTunAddr tunAddr: String) -> String {
        let ip = tunIP(tunAddr)
        let parts = ip.split(separator: ".").map(String.init)
        guard parts.count == 4,
              parts.allSatisfy({ UInt8($0) != nil })
        else {
            return fallbackHost
        }
        return "\(parts[0]).\(parts[1]).\(parts[2]).1"
    }

    /// Admin API base URL for a profile — the tunnel-gateway host derived
    /// from `tunAddr`, port 8080, reachable only through the VPN tunnel.
    public static func adminBaseURL(for profile: VpnProfile) -> URL? {
        URL(string: "https://\(host(forTunAddr: profile.tunAddr)):8080")
    }

    private static func tunIP(_ tunAddr: String) -> String {
        (tunAddr
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init) ?? tunAddr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
