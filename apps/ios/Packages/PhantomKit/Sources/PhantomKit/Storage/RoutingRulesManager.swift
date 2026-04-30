import Foundation

public enum RoutingRuleSource: String, Codable, Sendable {
    case geoip
    case geosite
}

public struct RoutingRulePreset: Identifiable, Equatable, Sendable {
    public var source: RoutingRuleSource
    public var code: String
    public var labelKey: String

    public var id: String { "\(source.rawValue):\(code)" }

    public init(source: RoutingRuleSource, code: String, labelKey: String) {
        self.source = source
        self.code = code
        self.labelKey = labelKey
    }
}

public struct RoutingRuleInfo: Equatable, Sendable {
    public var source: RoutingRuleSource
    public var code: String
    public var sizeKb: Int
    public var lastUpdated: Date
    public var ruleCount: Int

    public init(
        source: RoutingRuleSource,
        code: String,
        sizeKb: Int,
        lastUpdated: Date,
        ruleCount: Int
    ) {
        self.source = source
        self.code = code
        self.sizeKb = sizeKb
        self.lastUpdated = lastUpdated
        self.ruleCount = ruleCount
    }
}

public struct RoutingRuleSet: Equatable, Sendable {
    public var ipv4Cidrs: [String]
    public var ipv6Cidrs: [String]
    public var missingCountryCodes: [String]

    public init(
        ipv4Cidrs: [String] = [],
        ipv6Cidrs: [String] = [],
        missingCountryCodes: [String] = []
    ) {
        self.ipv4Cidrs = ipv4Cidrs
        self.ipv6Cidrs = ipv6Cidrs
        self.missingCountryCodes = missingCountryCodes
    }
}

public enum RoutingRulesError: LocalizedError {
    case badURL
    case badStatus(Int)
    case invalidPayload
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid routing rules URL"
        case .badStatus(let status):
            return "Routing rules download failed with HTTP \(status)"
        case .invalidPayload:
            return "Downloaded routing rules are empty or invalid"
        case .storageUnavailable:
            return "Routing rules storage is unavailable"
        }
    }
}

public final class RoutingRulesManager {
    public static let shared = RoutingRulesManager()

    public static let countryPresets: [RoutingRulePreset] = [
        .init(source: .geoip, code: "ru", labelKey: "settings.country.ru"),
        .init(source: .geoip, code: "by", labelKey: "settings.country.by"),
        .init(source: .geoip, code: "kz", labelKey: "settings.country.kz"),
        .init(source: .geoip, code: "ua", labelKey: "settings.country.ua"),
        .init(source: .geoip, code: "cn", labelKey: "settings.country.cn"),
        .init(source: .geoip, code: "ir", labelKey: "settings.country.ir"),
        .init(source: .geoip, code: "private", labelKey: "settings.country.private")
    ]

    public static let domainPresets: [RoutingRulePreset] = [
        .init(source: .geosite, code: "cn", labelKey: "settings.geosite.cn"),
        .init(source: .geosite, code: "geolocation-cn", labelKey: "settings.geosite.geolocation.cn"),
        .init(source: .geosite, code: "category-ru", labelKey: "settings.geosite.category.ru"),
        .init(source: .geosite, code: "mailru", labelKey: "settings.geosite.mailru")
    ]

    private static let appGroupId = "group.com.ghoststream.vpn"
    private static let geoipBaseURL = "https://raw.githubusercontent.com/v2fly/geoip/release/text"
    private static let geositeBaseURL = "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data"
    private static let maxIPv4Prefix = 18
    private static let geoipFormatMarker = "# ghoststream-format: geoip-v2-mixed"

    private let baseDirectory: URL
    private let fileManager: FileManager
    private let session: URLSession

    public init(
        baseDirectory: URL? = nil,
        fileManager: FileManager = .default,
        session: URLSession = .shared
    ) {
        self.fileManager = fileManager
        self.session = session

        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let appGroup = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupId
        ) {
            self.baseDirectory = appGroup.appendingPathComponent("routing_rules", isDirectory: true)
        } else {
            let fallback = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? fileManager.temporaryDirectory
            self.baseDirectory = fallback
                .appendingPathComponent("GhostStream", isDirectory: true)
                .appendingPathComponent("routing_rules", isDirectory: true)
        }
    }

    public func sourceURL(for preset: RoutingRulePreset) -> URL? {
        switch preset.source {
        case .geoip:
            return URL(string: "\(Self.geoipBaseURL)/\(preset.code).txt")
        case .geosite:
            return URL(string: "\(Self.geositeBaseURL)/\(preset.code)")
        }
    }

    public func downloadedRules() -> [String: RoutingRuleInfo] {
        (Self.countryPresets + Self.domainPresets).reduce(into: [:]) { output, preset in
            guard let info = ruleInfo(for: preset) else { return }
            output[preset.id] = info
        }
    }

    public func ruleInfo(for preset: RoutingRulePreset) -> RoutingRuleInfo? {
        let file = fileURL(for: preset)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        let attrs = (try? fileManager.attributesOfItem(atPath: file.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
        let count = (try? String(contentsOf: file, encoding: .utf8))
            .map { countRules(in: $0, source: preset.source) } ?? 0

        return RoutingRuleInfo(
            source: preset.source,
            code: preset.code,
            sizeKb: max(1, size / 1024),
            lastUpdated: modified,
            ruleCount: count
        )
    }

    public func downloadRuleList(_ preset: RoutingRulePreset) async throws -> RoutingRuleInfo {
        guard let url = sourceURL(for: preset) else {
            throw RoutingRulesError.badURL
        }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw RoutingRulesError.badStatus(http.statusCode)
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw RoutingRulesError.invalidPayload
        }

        let normalized = normalize(raw, source: preset.source)
        guard countRules(in: normalized, source: preset.source) > 0 else {
            throw RoutingRulesError.invalidPayload
        }

        try ensureRulesDirectory()
        try normalized.write(to: fileURL(for: preset), atomically: true, encoding: .utf8)
        guard let info = ruleInfo(for: preset) else {
            throw RoutingRulesError.storageUnavailable
        }
        return info
    }

    public func deleteRuleList(_ preset: RoutingRulePreset) {
        try? fileManager.removeItem(at: fileURL(for: preset))
    }

    public func ensureCountryRules(countryCodes: [String]) async throws {
        for code in normalizedCountryCodes(countryCodes) {
            let preset = RoutingRulePreset(source: .geoip, code: code, labelKey: "")
            guard needsRuleRefresh(for: preset) else { continue }
            _ = try await downloadRuleList(preset)
        }
    }

    public func mergedCountryCidrs(countryCodes: [String]) -> [String] {
        mergedCountryRules(countryCodes: countryCodes).ipv4Cidrs
    }

    public func mergedCountryRules(countryCodes: [String]) -> RoutingRuleSet {
        var output: [String] = []
        var output6: [String] = []
        var missing: [String] = []
        var seen = Set<String>()
        var seen6 = Set<String>()

        for code in normalizedCountryCodes(countryCodes) {
            let preset = RoutingRulePreset(source: .geoip, code: code, labelKey: "")
            let file = fileURL(for: preset)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                missing.append(code)
                continue
            }
            let rules = Self.normalizeGeoipCidrs(from: text)
            for cidr in rules.ipv4Cidrs {
                if seen.insert(cidr).inserted {
                    output.append(cidr)
                }
            }
            for cidr in rules.ipv6Cidrs {
                if seen6.insert(cidr).inserted {
                    output6.append(cidr)
                }
            }
        }

        return RoutingRuleSet(
            ipv4Cidrs: output,
            ipv6Cidrs: output6,
            missingCountryCodes: missing
        )
    }

    public static func normalizeIPv4Cidrs(from text: String) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let cidr = normalizeIPv4Cidr(String(rawLine)) else { continue }
            if seen.insert(cidr).inserted {
                output.append(cidr)
            }
        }
        return output
    }

    public static func normalizeIPv6Cidrs(from text: String) -> [String] {
        RoutePolicySnapshot.normalizedIPv6Cidrs(from: text).valid
    }

    public static func normalizeGeoipCidrs(from text: String) -> (ipv4Cidrs: [String], ipv6Cidrs: [String]) {
        (
            ipv4Cidrs: normalizeIPv4Cidrs(from: text),
            ipv6Cidrs: normalizeIPv6Cidrs(from: text)
        )
    }

    func fileURL(for preset: RoutingRulePreset) -> URL {
        let folder = baseDirectory.appendingPathComponent(preset.source.rawValue, isDirectory: true)
        let ext = preset.source == .geoip ? "txt" : "list"
        return folder.appendingPathComponent("\(preset.code).\(ext)")
    }

    private func ensureRulesDirectory() throws {
        try fileManager.createDirectory(
            at: baseDirectory.appendingPathComponent(RoutingRuleSource.geoip.rawValue, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: baseDirectory.appendingPathComponent(RoutingRuleSource.geosite.rawValue, isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private func normalize(_ text: String, source: RoutingRuleSource) -> String {
        switch source {
        case .geoip:
            let rules = Self.normalizeGeoipCidrs(from: text)
            return ([Self.geoipFormatMarker] + rules.ipv4Cidrs + rules.ipv6Cidrs)
                .joined(separator: "\n")
        case .geosite:
            return text
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .joined(separator: "\n")
        }
    }

    private func countRules(in text: String, source: RoutingRuleSource) -> Int {
        switch source {
        case .geoip:
            let rules = Self.normalizeGeoipCidrs(from: text)
            return rules.ipv4Cidrs.count + rules.ipv6Cidrs.count
        case .geosite:
            return text.split(whereSeparator: \.isNewline).filter { raw in
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return !line.isEmpty && !line.hasPrefix("#")
            }.count
        }
    }

    private func needsRuleRefresh(for preset: RoutingRulePreset) -> Bool {
        let file = fileURL(for: preset)
        guard fileManager.fileExists(atPath: file.path) else { return true }
        guard preset.source == .geoip else { return false }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return !text.contains(Self.geoipFormatMarker)
    }

    private func normalizedCountryCodes(_ countryCodes: [String]) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        for code in countryCodes.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
            guard !code.isEmpty, seen.insert(code).inserted else { continue }
            output.append(code)
        }
        return output
    }

    private static func normalizeIPv4Cidr(_ raw: String) -> String? {
        let withoutComment = raw.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? ""
        let cidr = withoutComment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cidr.isEmpty, !cidr.contains(":") else { return nil }

        let parts = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...32).contains(prefix),
              let ipv4 = ipv4ToUInt32(String(parts[0]))
        else { return nil }

        let effectivePrefix = min(prefix, maxIPv4Prefix)
        let mask: UInt32 = effectivePrefix == 0
            ? 0
            : UInt32.max << UInt32(32 - effectivePrefix)
        let network = ipv4 & mask
        return "\(uint32ToIPv4(network))/\(effectivePrefix)"
    }

    private static func ipv4ToUInt32(_ ip: String) -> UInt32? {
        let octets = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }

        var output: UInt32 = 0
        for octet in octets {
            guard let value = UInt8(String(octet)) else { return nil }
            output = (output << 8) | UInt32(value)
        }
        return output
    }

    private static func uint32ToIPv4(_ value: UInt32) -> String {
        [
            (value >> 24) & 0xff,
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff
        ]
        .map { String($0) }
        .joined(separator: ".")
    }
}
