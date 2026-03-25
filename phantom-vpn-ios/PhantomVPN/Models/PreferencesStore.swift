import Foundation
import SwiftUI

final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    @Published var dnsServers: [String] {
        didSet { saveArray(dnsServers, key: Keys.dnsServers) }
    }
    @Published var splitRouting: Bool {
        didSet { defaults.set(splitRouting, forKey: Keys.splitRouting) }
    }
    @Published var directCountries: [String] {
        didSet { saveArray(directCountries, key: Keys.directCountries) }
    }
    @Published var perAppMode: String {
        didSet { defaults.set(perAppMode, forKey: Keys.perAppMode) }
    }
    @Published var perAppList: [String] {
        didSet { saveArray(perAppList, key: Keys.perAppList) }
    }
    @Published var themeMode: String {
        didSet { defaults.set(themeMode, forKey: Keys.theme) }
    }

    var colorScheme: ColorScheme? {
        switch themeMode {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let dnsServers = "dns_servers"
        static let splitRouting = "split_routing"
        static let directCountries = "direct_countries"
        static let perAppMode = "per_app_mode"
        static let perAppList = "per_app_list"
        static let theme = "theme"
    }

    private init() {
        defaults = UserDefaults(suiteName: AppPaths.appGroupId) ?? .standard
        dnsServers = defaults.stringArray(forKey: Keys.dnsServers) ?? ["1.1.1.1", "8.8.8.8"]
        splitRouting = defaults.bool(forKey: Keys.splitRouting)
        directCountries = defaults.stringArray(forKey: Keys.directCountries) ?? []
        perAppMode = defaults.string(forKey: Keys.perAppMode) ?? "all"
        perAppList = defaults.stringArray(forKey: Keys.perAppList) ?? []
        themeMode = defaults.string(forKey: Keys.theme) ?? "system"
    }

    func mergedConfig(profile: VpnProfile?) -> VpnConfig {
        VpnConfig(
            serverAddr: profile?.serverAddr ?? "",
            serverName: profile?.serverName ?? "",
            insecure: profile?.insecure ?? false,
            certPath: profile?.certPath ?? "",
            keyPath: profile?.keyPath ?? "",
            caCertPath: profile?.caCertPath ?? "",
            tunAddr: profile?.tunAddr ?? "10.7.0.2/24",
            dnsServers: profile?.dnsServers ?? dnsServers,
            splitRouting: profile?.splitRouting ?? splitRouting,
            directCountries: profile?.directCountries ?? directCountries,
            perAppMode: profile?.perAppMode ?? perAppMode,
            perAppList: profile?.perAppList ?? perAppList
        )
    }

    private func saveArray(_ value: [String], key: String) {
        defaults.set(value, forKey: key)
    }
}
