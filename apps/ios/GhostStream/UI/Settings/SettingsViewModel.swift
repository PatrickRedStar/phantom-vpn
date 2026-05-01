//
//  SettingsViewModel.swift
//  GhostStream
//
//  Observable state for the Settings screen. Bridges `ProfilesStore`,
//  `PreferencesStore`, the Rust conn-string parser and a small TCP ping.
//

import PhantomUI
import Foundation
import Network
import Observation
import PhantomKit
import os.log

/// Errors raised by `SettingsViewModel.importFromString`.
public enum SettingsImportError: LocalizedError {
    case invalidConnString

    public var errorDescription: String? {
        switch self {
        case .invalidConnString:
            return "Не удалось распознать строку подключения. Проверьте ghs://…"
        }
    }
}

/// ViewModel for the Settings screen. Owns ping results, subscription cache
/// and mutating helpers for global preferences + the active profile.
@MainActor
@Observable
public final class SettingsViewModel {

    // MARK: - Dependencies

    private let profilesStore: ProfilesStore
    private let preferencesStore: PreferencesStore
    private let tunnelController: VpnTunnelController
    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "SettingsViewModel")

    // MARK: - Public state

    /// Measured latencies keyed by `VpnProfile.id`. Missing entries = never
    /// pinged. Negative value = unreachable / failed.
    public private(set) var pingResults: [String: Int] = [:]
    /// IDs of profiles currently being pinged.
    public private(set) var pinging: Set<String> = []
    /// Cached subscription status strings keyed by profile id (for display
    /// on the profile card).
    public private(set) var profileSubscriptions: [String: String] = [:]
    /// Downloaded V2Fly routing presets keyed as `geoip:ru`, `geosite:cn`, etc.
    public private(set) var downloadedRoutingRules: [String: RoutingRuleInfo] = [:]
    /// Presets currently being downloaded.
    public private(set) var downloadingRoutingRuleIds: Set<String> = []
    /// Last routing preset download status.
    public private(set) var routingDownloadStatus: String?
    /// Last import / rename error; nil when cleared.
    public private(set) var lastError: String?

    // MARK: - Init

    public init(
        profilesStore: ProfilesStore = .shared,
        preferencesStore: PreferencesStore = .shared,
        tunnelController: VpnTunnelController? = nil
    ) {
        self.profilesStore = profilesStore
        self.preferencesStore = preferencesStore
        self.tunnelController = tunnelController ?? VpnTunnelController()
        refreshDownloadedRoutingRules()
    }

    // MARK: - Convenience accessors (pass-through to stores)

    public var profiles: [VpnProfile] { profilesStore.profiles }
    public var activeId: String? { profilesStore.activeId }
    public var activeProfile: VpnProfile? { profilesStore.activeProfile }

    public var dnsServers: [String] { preferencesStore.dnsServers ?? [] }
    public var splitRouting: Bool { preferencesStore.splitRouting ?? false }
    public var directCountries: [String] { preferencesStore.directCountries }
    public var manualDirectCidrsText: String { preferencesStore.manualDirectCidrsText }
    public var invalidManualDirectCidrs: [String] { preferencesStore.invalidManualDirectCidrs }
    public var customDirectDomainsText: String { preferencesStore.customDirectDomainsText }
    public var customDirectDomains: [String] { preferencesStore.customDirectDomains }
    var theme: ThemeOverride { ThemeOverride.current }
    public var languageOverride: String? { preferencesStore.languageOverride }

    // MARK: - Profile mutations

    /// Parses a connection string (ghs://…) via `PhantomBridge` and adds the
    /// resulting profile to `ProfilesStore`.
    /// - Throws: `SettingsImportError.invalidConnString` on parse failure.
    @discardableResult
    public func importFromString(_ raw: String) throws -> VpnProfile {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try profilesStore.importFromConnString(trimmed)
        } catch {
            lastError = SettingsImportError.invalidConnString.errorDescription
            throw SettingsImportError.invalidConnString
        }
    }

    /// Thin wrapper used by the QR scanner completion handler.
    @discardableResult
    public func importFromQRResult(_ payload: String) throws -> VpnProfile {
        try importFromString(payload)
    }

    /// Deletes a profile by id.
    public func deleteProfile(id: String) {
        profilesStore.remove(id: id)
        pingResults.removeValue(forKey: id)
        pinging.remove(id)
        profileSubscriptions.removeValue(forKey: id)
    }

    /// Renames an existing profile. No-op if the id does not exist.
    public func renameProfile(id: String, name: String) {
        guard var p = profilesStore.profiles.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        p.name = trimmed
        profilesStore.update(p)
    }

    /// Marks a profile as the active one.
    public func setActiveProfile(id: String) {
        profilesStore.setActive(id: id)
    }

    /// Replaces cert / tun data for an existing profile by re-importing a
    /// fresh conn string under the same id and name.
    public func reimport(id: String, rawConnString: String) throws {
        guard let existing = profilesStore.profiles.first(where: { $0.id == id }) else {
            throw SettingsImportError.invalidConnString
        }
        guard let parsed = PhantomBridge.parseConnString(
            rawConnString.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            throw SettingsImportError.invalidConnString
        }
        var updated = existing
        updated.serverAddr = parsed.serverAddr
        updated.serverName = parsed.serverName
        updated.certPem = parsed.certPem
        updated.keyPem = parsed.keyPem
        updated.tunAddr = parsed.tunAddr
        profilesStore.update(updated)
    }

    // MARK: - Preferences

    /// Updates the global DNS server list (nil / empty → system default).
    public func setDnsServers(_ servers: [String]) {
        let cleaned = servers
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        preferencesStore.dnsServers = cleaned.isEmpty ? nil : cleaned
    }

    /// Toggles global split-routing.
    public func setSplitRouting(_ on: Bool) {
        preferencesStore.splitRouting = on
    }

    public func setDirectCountries(_ codes: [String]) {
        preferencesStore.directCountries = codes
    }

    public func setManualDirectCidrsText(_ text: String) {
        preferencesStore.manualDirectCidrsText = text
    }

    public func setCustomDirectDomainsText(_ text: String) {
        preferencesStore.customDirectDomainsText = text
    }

    public func saveRoutingSettings(
        splitOn: Bool,
        selectedCountries: [String],
        manualCidrsText: String,
        directDomainsText: String
    ) async {
        routingDownloadStatus = "Saving route policy..."
        preferencesStore.splitRouting = splitOn
        preferencesStore.directCountries = selectedCountries
        preferencesStore.manualDirectCidrsText = manualCidrsText
        preferencesStore.customDirectDomainsText = directDomainsText

        guard let activeProfile else {
            routingDownloadStatus = "Route policy saved"
            refreshDownloadedRoutingRules()
            return
        }

        do {
            try await tunnelController.applyRoutePolicy(profile: activeProfile, preferences: preferencesStore)
            refreshDownloadedRoutingRules()
            let ipv4Count = preferencesStore.manualDirectCidrs.count
            let ipv6Count = preferencesStore.manualDirectIpv6Cidrs.count
            routingDownloadStatus = "Route policy applied · \(ipv4Count) IPv4 · \(ipv6Count) IPv6 manual rules"
        } catch {
            refreshDownloadedRoutingRules()
            routingDownloadStatus = "Route policy update failed: \(error.localizedDescription)"
            log.error("route policy update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func refreshDownloadedRoutingRules() {
        downloadedRoutingRules = RoutingRulesManager.shared.downloadedRules()
    }

    public func downloadRulePreset(_ preset: RoutingRulePreset) async {
        guard !downloadingRoutingRuleIds.contains(preset.id) else { return }
        downloadingRoutingRuleIds.insert(preset.id)
        routingDownloadStatus = "Downloading \(preset.code)…"
        defer {
            downloadingRoutingRuleIds.remove(preset.id)
            refreshDownloadedRoutingRules()
        }

        do {
            let info = try await RoutingRulesManager.shared.downloadRuleList(preset)
            routingDownloadStatus = "\(preset.code) downloaded · \(info.ruleCount) rules"
        } catch {
            routingDownloadStatus = "Download failed for \(preset.code): \(error.localizedDescription)"
            log.error("routing rule download failed \(preset.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func downloadCountryRules(_ codes: [String]) async {
        for code in codes {
            guard let preset = RoutingRulesManager.countryPresets.first(where: { $0.code == code }) else {
                continue
            }
            await downloadRulePreset(preset)
        }
    }

    /// Sets the theme override (`.system` / `.dark` / `.light`).
    func setTheme(_ override: ThemeOverride) {
        preferencesStore.theme = override.rawValue
    }

    /// Overrides app language. `nil` → follow system.
    public func setLanguage(_ code: String?) {
        preferencesStore.languageOverride = code
    }

    // MARK: - Ping

    /// Measures TCP connect latency to the profile's `serverAddr`. Returns
    /// nil on invalid address; a negative value for unreachable.
    /// Updates `pingResults` and `pinging` as a side effect.
    public func pingProfile(_ p: VpnProfile) async -> Int? {
        guard let (host, port) = Self.parseHostPort(p.serverAddr) else {
            return nil
        }
        pinging.insert(p.id)
        let ms = await Self.tcpConnectMs(host: host, port: port, timeout: 3.0)
        pinging.remove(p.id)
        pingResults[p.id] = ms ?? -1
        return ms
    }

    /// Refreshes ping for every profile sequentially. Kicked off from the
    /// Settings view on appear.
    public func refreshPings() async {
        for p in profilesStore.profiles {
            _ = await pingProfile(p)
        }
    }

    /// Refreshes cached admin/subscription state for the active connected
    /// profile. The admin API is reachable only through that tunnel, so this
    /// intentionally does not probe inactive profiles.
    public func refreshSubscriptions() async {
        if let profile = await ProfileEntitlementRefresher.refreshActiveProfileIfConnected(
            profilesStore: profilesStore
        ) {
            if let text = ProfileEntitlementRefresher.subscriptionText(for: profile) {
                profileSubscriptions[profile.id] = text
            } else {
                profileSubscriptions.removeValue(forKey: profile.id)
            }
            return
        }

        for profile in profilesStore.profiles {
            if let text = ProfileEntitlementRefresher.subscriptionText(for: profile) {
                profileSubscriptions[profile.id] = text
            } else {
                profileSubscriptions.removeValue(forKey: profile.id)
            }
        }
    }

    // MARK: - Helpers

    /// Splits an `addr:port` string. IPv6 is not supported here — serverAddr
    /// is always an IPv4 or DNS name with a port.
    static func parseHostPort(_ addr: String) -> (String, UInt16)? {
        let trimmed = addr.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        let host = String(trimmed[..<colon])
        let portStr = String(trimmed[trimmed.index(after: colon)...])
        guard let port = UInt16(portStr), !host.isEmpty else { return nil }
        return (host, port)
    }

    /// Performs a single TCP connect and returns the elapsed milliseconds,
    /// or `nil` on failure / timeout.
    ///
    /// Internally uses an actor to ensure the continuation is resumed
    /// exactly once across three possible sources: `.ready`, `.failed`
    /// / `.cancelled`, or the timeout racer.
    static func tcpConnectMs(host: String, port: UInt16, timeout: TimeInterval) async -> Int? {
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let conn = NWConnection(host: nwHost, port: nwPort, using: .tcp)
        let start = DispatchTime.now()
        let gate = _PingGate()

        return await withCheckedContinuation { (cont: CheckedContinuation<Int?, Never>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = DispatchTime.now().uptimeNanoseconds
                        - start.uptimeNanoseconds
                    let ms = Int(elapsed / 1_000_000)
                    conn.cancel()
                    Task { await gate.resume(cont: cont, value: ms) }
                case .failed, .cancelled:
                    Task { await gate.resume(cont: cont, value: nil) }
                default:
                    break
                }
            }
            conn.start(queue: .global(qos: .userInitiated))

            // Timeout racer.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                conn.cancel()
                await gate.resume(cont: cont, value: nil)
            }
        }
    }
}

/// Small actor ensuring a `CheckedContinuation` resumes exactly once.
/// Used by `SettingsViewModel.tcpConnectMs` to race a TCP connect attempt
/// against a timeout without double-resume crashes.
private actor _PingGate {
    private var resumed = false
    func resume(cont: CheckedContinuation<Int?, Never>, value: Int?) {
        guard !resumed else { return }
        resumed = true
        cont.resume(returning: value)
    }
}
