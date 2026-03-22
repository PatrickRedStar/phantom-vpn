import Foundation

struct ParsedConnString {
    let addr: String
    let sni: String
    let tun: String
    let cert: String
    let key: String
    let ca: String?
    let adminUrl: String?
    let adminToken: String?
}

enum ConnStringParser {
    static func parse(_ input: String) throws -> ParsedConnString {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonData: Data

        if trimmed.hasPrefix("{") {
            jsonData = Data(trimmed.utf8)
        } else {
            var padded = trimmed
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let rem = padded.count % 4
            if rem > 0 { padded += String(repeating: "=", count: 4 - rem) }
            guard let d = Data(base64Encoded: padded) else {
                throw NSError(domain: "ConnString", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Неверный формат строки подключения"])
            }
            jsonData = d
        }

        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(domain: "ConnString", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ошибка разбора JSON"])
        }

        let admin = obj["admin"] as? [String: Any]
        return ParsedConnString(
            addr:       obj["addr"] as? String ?? "",
            sni:        obj["sni"]  as? String ?? "",
            tun:        obj["tun"]  as? String ?? "",
            cert:       obj["cert"] as? String ?? "",
            key:        obj["key"]  as? String ?? "",
            ca:         obj["ca"]   as? String,
            adminUrl:   admin?["url"]   as? String,
            adminToken: admin?["token"] as? String
        )
    }
}
