import Foundation

struct VpnProfile: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String = "Подключение"
    var connString: String
    var adminUrl: String?
    var adminToken: String?

    // Derived — parsed on demand
    var serverAddr: String { (try? ConnStringParser.parse(connString))?.addr ?? "" }
    var tunAddr: String    { (try? ConnStringParser.parse(connString))?.tun ?? "" }
}
