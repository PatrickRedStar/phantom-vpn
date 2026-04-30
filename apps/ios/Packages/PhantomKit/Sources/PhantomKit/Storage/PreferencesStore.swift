// PreferencesStore — App Group UserDefaults-backed settings singleton.

import Foundation
import Observation

/// Global application preferences. Backed by
/// `UserDefaults(suiteName: "group.com.ghoststream.vpn")` so the Packet
/// Tunnel Provider extension can read the same keys the main app writes.
///
/// Semantic notes (iOS vs Android):
/// - `autoStartOnBoot` — iOS cannot auto-start a VPN from cold boot. The
///   flag is retained for UI parity but nothing in the iOS stack reads it.
/// - `perAppMode` / `perAppList` — retained for Android schema parity only.
@MainActor
@Observable
public final class PreferencesStore {

    /// Process-wide shared instance.
    public static let shared = PreferencesStore()

    private let defaults: UserDefaults

    // MARK: - Keys

    private enum Key {
        static let dnsServers        = "dns_servers"
        static let splitRouting      = "split_routing"
        static let routingMode       = "routing_mode"
        static let manualDirectCidrs = "manual_direct_cidrs"
        static let directCountries   = "direct_countries"
        static let customDirectDomains = "custom_direct_domains"
        static let preserveScopedDns = "preserve_scoped_dns"
        static let perAppMode        = "per_app_mode"
        static let perAppList        = "per_app_list"
        static let autoStartOnBoot   = "auto_start_on_boot"
        static let wasRunning        = "was_running"
        static let lastTunnelParams  = "last_tunnel_params"
        static let languageOverride  = "language_override"
        static let theme             = "theme"
        static let dnsLeakProtection = "dns_leak_protection"
        static let ipv6Killswitch    = "ipv6_killswitch"
        static let autoReconnect     = "auto_reconnect"
        static let startInMenuBar    = "start_in_menu_bar"
        static let notifyStateChanges = "notify_state_changes"
        static let reduceMotion      = "reduce_motion"
        static let autoUpdate        = "auto_update"
        static let streams           = "streams"
    }

    /// Stored property so `@Observable` can track changes and trigger SwiftUI
    /// re-renders. Synced to UserDefaults in `didSet`.
    public var theme: String = "dark" {
        didSet { defaults.set(theme, forKey: Key.theme) }
    }

    /// Stored property so `@Observable` can track changes.
    public var languageOverride: String? = nil {
        didSet {
            if let v = languageOverride { defaults.set(v, forKey: Key.languageOverride) }
            else { defaults.removeObject(forKey: Key.languageOverride) }
        }
    }

    public var dnsLeakProtection: Bool = true {
        didSet { defaults.set(dnsLeakProtection, forKey: Key.dnsLeakProtection) }
    }

    public var ipv6Killswitch: Bool = true {
        didSet { defaults.set(ipv6Killswitch, forKey: Key.ipv6Killswitch) }
    }

    public var autoReconnect: Bool = true {
        didSet { defaults.set(autoReconnect, forKey: Key.autoReconnect) }
    }

    public var startInMenuBar: Bool = false {
        didSet { defaults.set(startInMenuBar, forKey: Key.startInMenuBar) }
    }

    public var notifyStateChanges: Bool = true {
        didSet { defaults.set(notifyStateChanges, forKey: Key.notifyStateChanges) }
    }

    public var reduceMotion: Bool = false {
        didSet { defaults.set(reduceMotion, forKey: Key.reduceMotion) }
    }

    public var autoUpdate: Bool = false {
        didSet { defaults.set(autoUpdate, forKey: Key.autoUpdate) }
    }

    public var streams: Int = 8 {
        didSet {
            let clamped = max(2, min(16, streams))
            if streams != clamped {
                streams = clamped
            } else {
                defaults.set(streams, forKey: Key.streams)
            }
        }
    }

    public var routingMode: RoutingMode = .global {
        didSet {
            guard !isAssigningRoutingModeWithoutPersistence else { return }
            routingModeExplicitlySet = true
            defaults.set(routingMode.rawValue, forKey: Key.routingMode)
            if let legacyValue = routingMode.legacySplitRoutingValue {
                defaults.set(legacyValue, forKey: Key.splitRouting)
            }
        }
    }

    private var routingModeExplicitlySet = false
    private var isAssigningRoutingModeWithoutPersistence = false

    public var manualDirectCidrsText: String = "" {
        didSet { defaults.set(manualDirectCidrsText, forKey: Key.manualDirectCidrs) }
    }

    public var preserveScopedDns: Bool = true {
        didSet { defaults.set(preserveScopedDns, forKey: Key.preserveScopedDns) }
    }

    private init() {
        self.defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")!
        // Hydrate stored properties from UserDefaults
        self.theme = defaults.string(forKey: Key.theme) ?? "dark"
        self.languageOverride = defaults.string(forKey: Key.languageOverride)
        self.dnsLeakProtection = defaults.object(forKey: Key.dnsLeakProtection) as? Bool ?? true
        self.ipv6Killswitch = defaults.object(forKey: Key.ipv6Killswitch) as? Bool ?? true
        self.autoReconnect = defaults.object(forKey: Key.autoReconnect) as? Bool ?? true
        self.startInMenuBar = defaults.object(forKey: Key.startInMenuBar) as? Bool ?? false
        self.notifyStateChanges = defaults.object(forKey: Key.notifyStateChanges) as? Bool ?? true
        self.reduceMotion = defaults.object(forKey: Key.reduceMotion) as? Bool ?? false
        self.autoUpdate = defaults.object(forKey: Key.autoUpdate) as? Bool ?? false
        let storedStreams = defaults.object(forKey: Key.streams) as? Int ?? 8
        self.streams = max(2, min(16, storedStreams))
        let legacySplitRouting = defaults.object(forKey: Key.splitRouting) as? Bool
        if let storedRoutingMode = defaults.string(forKey: Key.routingMode),
           let mode = RoutingMode(rawValue: storedRoutingMode) {
            self.routingMode = mode
            self.routingModeExplicitlySet = true
        } else if let legacySplitRouting {
            self.routingMode = RoutingMode.defaultValue(splitRouting: legacySplitRouting)
            self.routingModeExplicitlySet = true
        } else {
            self.routingMode = .global
            self.routingModeExplicitlySet = false
        }
        self.manualDirectCidrsText = defaults.string(forKey: Key.manualDirectCidrs) ?? ""
        self.preserveScopedDns = defaults.object(forKey: Key.preserveScopedDns) as? Bool ?? true
    }

    // MARK: - DNS

    /// Global DNS server list. nil = system default.
    public var dnsServers: [String]? {
        get {
            guard let joined = defaults.string(forKey: Key.dnsServers), !joined.isEmpty else {
                return nil
            }
            return joined.split(separator: ",").map { String($0) }
        }
        set {
            if let v = newValue, !v.isEmpty {
                defaults.set(v.joined(separator: ","), forKey: Key.dnsServers)
            } else {
                defaults.removeObject(forKey: Key.dnsServers)
            }
        }
    }

    // MARK: - Routing

    /// Whether split-routing is enabled globally. nil = unset.
    public var splitRouting: Bool? {
        get {
            routingModeExplicitlySet ? routingMode.legacySplitRoutingValue : nil
        }
        set {
            if let v = newValue {
                routingMode = RoutingMode.defaultValue(splitRouting: v)
            } else {
                defaults.removeObject(forKey: Key.splitRouting)
                defaults.removeObject(forKey: Key.routingMode)
                setRoutingModeWithoutPersisting(.global, explicitlySet: false)
            }
        }
    }

    public func effectiveRoutingMode(profileSplitRouting: Bool?) -> RoutingMode {
        routingModeExplicitlySet
            ? routingMode
            : RoutingMode.defaultValue(splitRouting: profileSplitRouting)
    }

    private func setRoutingModeWithoutPersisting(
        _ mode: RoutingMode,
        explicitlySet: Bool
    ) {
        isAssigningRoutingModeWithoutPersistence = true
        routingMode = mode
        routingModeExplicitlySet = explicitlySet
        isAssigningRoutingModeWithoutPersistence = false
    }

    public var manualDirectCidrs: [String] {
        RoutePolicySnapshot.normalizedCidrs(from: manualDirectCidrsText).valid
    }

    public var invalidManualDirectCidrs: [String] {
        RoutePolicySnapshot.normalizedCidrs(from: manualDirectCidrsText).invalid
    }

    public var directCountries: [String] {
        get {
            guard let joined = defaults.string(forKey: Key.directCountries),
                  !joined.isEmpty
            else { return [] }
            return joined
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
                .uniquedPreservingOrder()
            if cleaned.isEmpty {
                defaults.removeObject(forKey: Key.directCountries)
            } else {
                defaults.set(cleaned.joined(separator: ","), forKey: Key.directCountries)
            }
        }
    }

    public var customDirectDomainsText: String {
        get { defaults.string(forKey: Key.customDirectDomains) ?? "" }
        set { defaults.set(newValue, forKey: Key.customDirectDomains) }
    }

    public var customDirectDomains: [String] {
        Self.normalizedHostnames(from: customDirectDomainsText)
    }

    nonisolated public static func normalizedHostnames(from text: String) -> [String] {
        var output: [String] = []
        var seen = Set<String>()

        for rawToken in text.split(whereSeparator: { ch in
            ch.isWhitespace || ch == "," || ch == ";"
        }) {
            var token = String(rawToken)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !token.isEmpty else { continue }
            if token.hasPrefix("#") { continue }
            if token.hasPrefix("domain:") {
                token.removeFirst("domain:".count)
            } else if token.hasPrefix("full:") {
                token.removeFirst("full:".count)
            }
            if token.hasPrefix("http://") || token.hasPrefix("https://") {
                token = URL(string: token)?.host ?? token
            }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard isResolvableHostname(token), seen.insert(token).inserted else { continue }
            output.append(token)
        }

        return output
    }

    nonisolated private static func isResolvableHostname(_ value: String) -> Bool {
        guard value.count <= 253,
              value.contains("."),
              !value.contains(":"),
              !value.hasPrefix("geosite:"),
              !value.hasPrefix("keyword:"),
              !value.hasPrefix("regexp:"),
              !value.hasPrefix("include:")
        else { return false }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }

        return value
            .split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { part in
                guard !part.isEmpty, part.count <= 63 else { return false }
                return part.first != "-" && part.last != "-"
            }
    }

    // MARK: - Per-app (iOS-ignored — kept for Android schema parity)

    /// iOS-ignored; retained for Android schema compatibility.
    public var perAppMode: String? {
        get { defaults.string(forKey: Key.perAppMode) }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.perAppMode) }
            else { defaults.removeObject(forKey: Key.perAppMode) }
        }
    }

    /// iOS-ignored; retained for Android schema compatibility.
    public var perAppList: [String]? {
        get { defaults.stringArray(forKey: Key.perAppList) }
        set {
            if let v = newValue { defaults.set(v, forKey: Key.perAppList) }
            else { defaults.removeObject(forKey: Key.perAppList) }
        }
    }

    // MARK: - Runtime flags

    /// UI-toggleable flag. iOS has no OS hook to auto-start a VPN from
    /// cold boot — this is a no-op on iOS runtime.
    public var autoStartOnBoot: Bool {
        get { defaults.bool(forKey: Key.autoStartOnBoot) }
        set { defaults.set(newValue, forKey: Key.autoStartOnBoot) }
    }

    /// "Was I running before the process was killed?" — used to decide
    /// whether to auto-reconnect on app resume.
    public var wasRunning: Bool {
        get { defaults.bool(forKey: Key.wasRunning) }
        set { defaults.set(newValue, forKey: Key.wasRunning) }
    }

    /// Updates `wasRunning`. Exposed as a function for call-site clarity.
    public func setWasRunning(_ running: Bool) { wasRunning = running }

    // MARK: - Tunnel params snapshot

    /// JSON blob snapshot of the last tunnel-start configuration. Used by
    /// the reconnect flow when the app is resumed after a process kill.
    public func saveLastTunnelParams(_ json: String) {
        defaults.set(json, forKey: Key.lastTunnelParams)
    }

    /// Returns the last snapshot passed to `saveLastTunnelParams`, if any.
    public func loadLastTunnelParams() -> String? {
        defaults.string(forKey: Key.lastTunnelParams)
    }

    // MARK: - Locale / theme

    // `theme` and `languageOverride` are stored properties declared near
    // init() so `@Observable` can track them for SwiftUI reactivity.
}

private extension Array where Element == String {
    func uniquedPreservingOrder() -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for item in self where seen.insert(item).inserted {
            output.append(item)
        }
        return output
    }
}
