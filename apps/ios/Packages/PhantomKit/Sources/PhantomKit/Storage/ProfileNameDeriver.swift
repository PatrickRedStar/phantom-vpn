import Foundation
import Security

/// Derives a human-readable profile name from an imported connection string.
public enum ProfileNameDeriver {
    public static let fallbackName = "Подключение"

    public static func defaultName(for parsed: ParsedConnConfig) -> String {
        certificateCommonName(from: parsed.certPem)
            ?? firstServerNameLabel(parsed.serverName)
            ?? fallbackName
    }

    public static func certificateCommonName(from certPem: String) -> String? {
        guard let der = firstCertificateDER(from: certPem),
              let cert = SecCertificateCreateWithData(nil, der as CFData),
              let summary = SecCertificateCopySubjectSummary(cert) as String?
        else {
            return nil
        }
        return cleanedName(summary)
    }

    public static func firstServerNameLabel(_ serverName: String) -> String? {
        let label = serverName
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? serverName
        return cleanedName(label)
    }

    private static func firstCertificateDER(from pem: String) -> Data? {
        let pattern = "-----BEGIN CERTIFICATE-----([\\s\\S]*?)-----END CERTIFICATE-----"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = pem as NSString
        guard let match = regex.firstMatch(in: pem, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let b64 = ns.substring(with: match.range(at: 1))
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Data(base64Encoded: b64)
    }

    private static func cleanedName(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
