import Foundation

/// Payload passed as `cfg_json` to `phantom_runtime_start`.
/// Contains the connection string and runtime settings for one tunnel session.
public struct ConnectProfile: Codable {
    public var name: String
    public var connString: String
    public var settings: TunnelSettings

    enum CodingKeys: String, CodingKey {
        case name
        case connString = "conn_string"
        case settings
    }

    public init(name: String, connString: String, settings: TunnelSettings = TunnelSettings()) {
        self.name = name
        self.connString = connString
        self.settings = settings
    }
}
