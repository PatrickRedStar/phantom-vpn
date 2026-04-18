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
/// - `perAppMode` / `perAppList` — iOS does not expose per-app VPN routing
///   to third-party apps. Retained for schema parity only.
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
        static let perAppMode        = "per_app_mode"
        static let perAppList        = "per_app_list"
        static let autoStartOnBoot   = "auto_start_on_boot"
        static let wasRunning        = "was_running"
        static let lastTunnelParams  = "last_tunnel_params"
        static let languageOverride  = "language_override"
        static let theme             = "theme"
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

    private init() {
        self.defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")!
        // Hydrate stored properties from UserDefaults
        self.theme = defaults.string(forKey: Key.theme) ?? "dark"
        self.languageOverride = defaults.string(forKey: Key.languageOverride)
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
        get { defaults.object(forKey: Key.splitRouting) as? Bool }
        set {
            if let v = newValue {
                defaults.set(v, forKey: Key.splitRouting)
            } else {
                defaults.removeObject(forKey: Key.splitRouting)
            }
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
