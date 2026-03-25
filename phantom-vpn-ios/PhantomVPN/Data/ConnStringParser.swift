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
            if rem > 0 {
                padded += String(repeating: "=", count: 4 - rem)
            }
            guard let d = Data(base64Encoded: padded) else {
                throw NSError(
                    domain: "ConnString",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Неверный формат строки подключения"]
                )
            }
            jsonData = d
        }

        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(
                domain: "ConnString",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Ошибка разбора JSON"]
            )
        }

        let admin = obj["admin"] as? [String: Any]
        return ParsedConnString(
            addr: obj["addr"] as? String ?? "",
            sni: obj["sni"] as? String ?? "",
            tun: obj["tun"] as? String ?? "",
            cert: obj["cert"] as? String ?? "",
            key: obj["key"] as? String ?? "",
            ca: obj["ca"] as? String,
            adminUrl: admin?["url"] as? String,
            adminToken: admin?["token"] as? String
        )
    }

    static func build(profile: VpnProfile) -> String? {
        guard let cert = try? String(contentsOfFile: profile.certPath, encoding: .utf8),
              let key = try? String(contentsOfFile: profile.keyPath, encoding: .utf8) else {
            return nil
        }
        let ca = profile.caCertPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        var json: [String: Any] = [
            "v": 1,
            "addr": profile.serverAddr,
            "sni": profile.serverName,
            "tun": profile.tunAddr,
            "cert": cert,
            "key": key
        ]
        if let ca {
            json["ca"] = ca
        }
        if let adminUrl = profile.adminUrl, let adminToken = profile.adminToken {
            json["admin"] = ["url": adminUrl, "token": adminToken]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              var encoded = data.base64EncodedString() as String? else {
            return nil
        }
        encoded = encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return encoded
    }
}
