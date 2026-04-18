// ConnStringBuilder — rebuilds a ghs:// URL from stored VpnProfile fields.
// Mirrors Android's ConnStringParser.build().

import Foundation

public enum ConnStringBuilder {

    /// Rebuilds a `ghs://` connection string from a VpnProfile's fields.
    /// Returns nil if cert/key PEMs are missing.
    ///
    /// Format: `ghs://<base64url(certPem + "\n" + keyPem)>@<host:port>?sni=<sni>&tun=<cidr>&v=1`
    public static func build(from profile: VpnProfile) -> String? {
        guard let certPem = profile.certPem, !certPem.isEmpty,
              let keyPem = profile.keyPem, !keyPem.isEmpty
        else { return nil }

        let pem = certPem.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n"
            + keyPem.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let pemData = pem.data(using: .utf8) else { return nil }

        // Base64url encoding (no padding, URL-safe alphabet)
        let userinfo = pemData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let sni = profile.serverName
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile.serverName
        let tun = profile.tunAddr
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? profile.tunAddr

        return "ghs://\(userinfo)@\(profile.serverAddr)?sni=\(sni)&tun=\(tun)&v=1"
    }
}
