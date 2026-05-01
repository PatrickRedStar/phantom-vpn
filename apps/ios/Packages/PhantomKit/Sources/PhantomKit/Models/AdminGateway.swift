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

    private static func tunIP(_ tunAddr: String) -> String {
        tunAddr
            .split(separator: "/", maxSplits: 1)
            .first
            .map(String.init) ?? tunAddr
    }
}
