import Foundation

struct VpnProfile: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "Подключение"
    var serverAddr: String = ""
    var serverName: String = ""
    var insecure: Bool = false
    var certPath: String = ""
    var keyPath: String = ""
    var caCertPath: String? = nil
    var tunAddr: String = "10.7.0.2/24"
    var adminUrl: String? = nil
    var adminToken: String? = nil

    // Per-profile overrides (nil = use global defaults)
    var dnsServers: [String]? = nil
    var splitRouting: Bool? = nil
    var directCountries: [String]? = nil
    var perAppMode: String? = nil
    var perAppList: [String]? = nil

    // Cached subscription info
    var cachedExpiresAt: Int64? = nil
    var cachedEnabled: Bool? = nil
}

struct VpnStats: Codable {
    let bytes_rx: UInt64
    let bytes_tx: UInt64
    let pkts_rx: UInt64
    let pkts_tx: UInt64
    let connected: Bool
}

struct VpnConfig: Codable {
    var serverAddr: String = ""
    var serverName: String = ""
    var insecure: Bool = false
    var certPath: String = ""
    var keyPath: String = ""
    var caCertPath: String = ""
    var tunAddr: String = "10.7.0.2/24"
    var dnsServers: [String] = ["1.1.1.1", "8.8.8.8"]
    var splitRouting: Bool = false
    var directCountries: [String] = []
    var perAppMode: String = "all"
    var perAppList: [String] = []
}
