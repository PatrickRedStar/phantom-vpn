import Foundation

final class RoutingRulesManager {
    static let shared = RoutingRulesManager()
    static let allCountryCodes = ["ru", "us", "de", "fr", "gb", "nl", "sg", "jp", "ae", "tr", "ua", "kz"]

    private let fm = FileManager.default
    private let rulesDir: URL
    private let mergedFileName = "selected_merged.txt"
    private let androidMaxPrefix = 18

    private init() {
        let base = AppPaths.sharedContainerURL()
        rulesDir = base.appendingPathComponent("routing_rules", isDirectory: true)
        try? fm.createDirectory(at: rulesDir, withIntermediateDirectories: true)
    }

    func sourceUrl(code: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/v2fly/geoip/release/text/\(code).txt")!
    }

    func listPath(for code: String) -> URL {
        rulesDir.appendingPathComponent("\(code).txt")
    }

    func missingSelectedLists(codes: [String]) -> [String] {
        codes.filter { !fm.fileExists(atPath: listPath(for: $0).path) }
    }

    func downloadRuleList(code: String) async throws {
        let url = sourceUrl(code: code)
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "RoutingRules", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ошибка загрузки \(code)"])
        }
        try data.write(to: listPath(for: code), options: .atomic)
    }

    func downloadAllSelected(codes: [String]) async throws {
        for code in codes {
            try await downloadRuleList(code: code)
        }
    }

    func mergeSelectedLists(codes: [String]) throws -> String {
        let merged = rulesDir.appendingPathComponent(mergedFileName)
        var out = ""
        var dedup = Set<String>()

        for code in codes {
            let p = listPath(for: code)
            guard let text = try? String(contentsOf: p, encoding: .utf8) else { continue }
            text.split(separator: "\n").forEach { line in
                if let cidr = normalizeForIOSSplitRouting(String(line)), !dedup.contains(cidr) {
                    dedup.insert(cidr)
                    out.append(cidr)
                    out.append("\n")
                }
            }
        }
        try out.write(to: merged, atomically: true, encoding: .utf8)
        return merged.path
    }

    private func normalizeForIOSSplitRouting(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("#") || s.contains(":") { return nil }
        let parts = s.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), prefix >= 0, prefix <= 32 else { return nil }
        let cappedPrefix = min(prefix, androidMaxPrefix)
        return "\(parts[0])/\(cappedPrefix)"
    }
}
