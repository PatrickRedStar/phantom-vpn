//
//  VpnTunnelController.swift
//  GhostStream (macOS)
//
//  Thin wrapper over `NETunnelProviderManager`. Adapted from
//  apps/ios/GhostStream/Service/VpnTunnelController.swift, with macOS-
//  specific provider bundle id derivation.
//

import Foundation
import NetworkExtension
import PhantomKit
import os.log

public enum VpnTunnelError: LocalizedError {
    case noManager
    case saveFailed(String)
    case reloadFailed(String)
    case startFailed(String)
    case encoding

    public var errorDescription: String? {
        switch self {
        case .noManager:            return "VPN configuration not loaded"
        case .saveFailed(let msg):  return "Failed to save VPN configuration: \(msg)"
        case .reloadFailed(let msg): return "Failed to reload VPN configuration: \(msg)"
        case .startFailed(let msg): return "Failed to start VPN tunnel: \(msg)"
        case .encoding:             return "Failed to encode provider configuration"
        }
    }
}

@MainActor
public final class VpnTunnelController: ObservableObject {

    @Published public private(set) var manager: NETunnelProviderManager?
    @Published public var lastError: String?

    /// UI-R4-R06: a session is "successful" once it has been observed in
    /// the `.connected` state at least once since the last error reset.
    /// Round 2 tracked this via `@State wasConnected` on every consumer
    /// view (DashboardView, MenuBarPopover) which had two failure modes:
    /// (a) the state vanished when the user switched between the popover
    /// and the dashboard (each view owned its own copy), and (b) the
    /// "clear `lastError` after a successful round-trip" effect raced
    /// per-view. We hoist the flag into the Service layer so the
    /// truth is shared across all surfaces and survives view
    /// reparenting.
    @Published public var hadSuccessfulConnect: Bool = false

    /// macOS system-extension bundle id. Hardcoded against the project.yml
    /// extension bundle id; on iOS this would be derived from the host
    /// bundle id, but on macOS the system extension is a sibling, not a
    /// child.
    private let providerBundleId = "com.ghoststream.client.tunnel"

    private let log = Logger(subsystem: "com.ghoststream.client", category: "VpnTunnelController")

    public init() {}

    /// UI-R4-R06: drive the `hadSuccessfulConnect` flag from the
    /// canonical `VpnStateManager.statusFrame.state` stream. Views
    /// (DashboardView / MenuBarPopover / TailView) used to race on
    /// `wasConnected` from local `@State`; we now centralise the
    /// transition logic here. Callers feed every state change in via
    /// this entry point so the flag flips exactly once per session
    /// boundary, independent of which surface is mounted at the time.
    ///
    /// Side effect: when the tunnel returns to `.disconnected` after a
    /// successful `.connected` round-trip, `lastError` is cleared too
    /// — that's the same "benign disconnect" semantics the per-view
    /// `.onChange` handlers had before.
    public func observeStateForSuccessTracking(_ newState: ConnState) {
        if newState == .connected {
            if !hadSuccessfulConnect {
                hadSuccessfulConnect = true
            }
        } else if newState == .disconnected && hadSuccessfulConnect {
            lastError = nil
            hadSuccessfulConnect = false
        }
    }

    public func loadFromPreferences(expectedProfileId: String? = nil) async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = selectManager(
            from: ghostStreamManagers(in: all),
            expectedProfileId: expectedProfileId
        ) {
            manager = existing
        } else {
            manager = NETunnelProviderManager()
        }
    }

    /// Configure & save a `NETunnelProviderManager` without starting the
    /// tunnel. macOS surfaces the "Allow VPN configuration" permission
    /// dialog the first time `saveToPreferences` succeeds — used by the
    /// onboarding wizard to gate that consent moment.
    public func installOnly(
        profile: VpnProfile,
        preferences: PreferencesStore? = nil
    ) async throws {
        lastError = nil
        let preferences = preferences ?? PreferencesStore.shared

        var providerProfile = profile
        let effectiveRoutingMode = preferences.effectiveRoutingMode(
            profileSplitRouting: profile.splitRouting
        )
        let dnsServers = preferences.dnsServers
        let manualDirectCidrs = preferences.manualDirectCidrs
        let preserveScopedDns = preferences.preserveScopedDns
        let dnsLeakProtection = preferences.dnsLeakProtection
        let ipv6Killswitch = preferences.ipv6Killswitch
        let autoReconnect = preferences.autoReconnect
        let streamOverride = preferences.streamOverride
        providerProfile.dnsServers = dnsServers ?? profile.dnsServers
        providerProfile.splitRouting = effectiveRoutingMode.legacySplitRoutingValue
        let routePolicyInput = UpstreamVpnRouteDetector.SnapshotInput(
            mode: effectiveRoutingMode,
            manualDirectCidrs: manualDirectCidrs,
            preserveScopedDns: preserveScopedDns,
            serverAddr: providerProfile.serverAddr,
            tunAddr: providerProfile.tunAddr
        )
        let routePolicy = await UpstreamVpnRouteDetector().snapshot(routePolicyInput)

        // CRITICAL privacy: NETunnelProviderProtocol.providerConfiguration is
        // persisted by the system in plaintext under
        // `/Library/Preferences/com.apple.networkextension*.plist`. Any
        // PEM material or the original `ghs://` conn-string (its userinfo
        // is base64-PEM) would be readable by every process with sudo.
        // The extension hydrates cert/key from the shared Keychain at
        // start time via `resolveProfile(id:)`, so we never need to ship
        // them through this dictionary.
        let profileData: Data
        let settingsData: Data
        do {
            // ━━━ INVARIANT — DO NOT SANITIZE certPem/keyPem ON macOS ━━━
            //
            // The macOS system extension runs as ROOT and does NOT have access
            // to the user's Data Protection Keychain where `ProfilesStore.save`
            // writes the PEM secrets. If we sanitize them out here, the
            // extension's `Keychain.get("profile.<id>.cert")` returns nil →
            // `ConnStringBuilder.build` returns nil → `BridgeError.encoding`
            // is thrown immediately after `tun_addr` is registered, the
            // tunnel cancels in ~5ms with no diagnostic in the UI logs.
            //
            // This took 5 rounds of audit→fix cycles to detect because the
            // bug only surfaces at RUNTIME — static analysis kept "patching"
            // the wrong invariant. See:
            //   docs/knowledge/incidents/2026-05-17-cert-pem-keychain-regression.md
            //   docs/knowledge/decisions/0009-cert-pem-providerConfiguration.md
            //
            // Trade-off: NEManager persists `providerConfiguration` in
            // `/Library/Preferences/com.apple.networkextension*.plist` which is
            // readable by `sudo`-privileged processes. A future fix (host XPC
            // bridge to forward PEM into extension on demand, or unprivileged
            // extension model) can revisit this; until then a working tunnel
            // beats a "secure" tunnel that never establishes.
            //
            // If you must change this — first add a runtime smoke test
            // (`apps/macos/scripts/smoke-test.sh`) that verifies an end-to-end
            // Connect succeeds AFTER your change. Static checks lie here.
            profileData = try JSONEncoder().encode(providerProfile)
            let settings = TunnelSettings(
                dnsLeakProtection: dnsLeakProtection,
                ipv6Killswitch: ipv6Killswitch,
                autoReconnect: autoReconnect,
                routingMode: effectiveRoutingMode,
                manualDirectCidrs: manualDirectCidrs,
                preserveScopedDns: preserveScopedDns,
                routePolicy: routePolicy,
                streams: streamOverride
            )
            settingsData = try JSONEncoder().encode(settings)
        } catch {
            let wrapped = VpnTunnelError.encoding
            lastError = wrapped.localizedDescription
            throw wrapped
        }

        let managerToSave: NETunnelProviderManager
        do {
            let all = try await NETunnelProviderManager.loadAllFromPreferences()
            let ghostManagers = ghostStreamManagers(in: all)
            logLoadedManagers(ghostManagers, currentProfileId: profile.id)
            managerToSave = selectManager(from: ghostManagers, expectedProfileId: profile.id)
                ?? NETunnelProviderManager()
        } catch {
            let wrapped = VpnTunnelError.reloadFailed(error.localizedDescription)
            lastError = wrapped.localizedDescription
            throw wrapped
        }

        let proto = NETunnelProviderProtocol()
        proto.serverAddress = profile.serverAddr
        proto.providerBundleIdentifier = providerBundleId
        proto.providerConfiguration = [
            "profile": profileData,
            "settings": settingsData,
        ]

        managerToSave.protocolConfiguration = proto
        managerToSave.localizedDescription = profile.name
        managerToSave.isEnabled = true

        do {
            log.info("saving GhostStream VPN manager profileId=\(profile.id, privacy: .public)")
            try await managerToSave.saveToPreferences()
            manager = try await reloadSavedManager(profileId: profile.id)
        } catch {
            log.error("saveToPreferences failed: \(error.localizedDescription, privacy: .public)")
            let wrapped = error as? VpnTunnelError ?? VpnTunnelError.saveFailed(error.localizedDescription)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    public func installAndStart(profile: VpnProfile, preferences: PreferencesStore) async throws {
        do {
            try await installOnly(profile: profile, preferences: preferences)
            guard let manager else { throw VpnTunnelError.noManager }
            guard providerProfileId(in: manager) == profile.id else {
                let configuredId = providerProfileId(in: manager) ?? "<missing>"
                throw VpnTunnelError.startFailed(
                    "VPN configuration has stale profileId \(configuredId); expected \(profile.id)"
                )
            }
            log.info("starting GhostStream VPN tunnel profileId=\(profile.id, privacy: .public)")
            try manager.connection.startVPNTunnel()
        } catch {
            log.error("startVPNTunnel failed: \(error.localizedDescription, privacy: .public)")
            let wrapped = error as? VpnTunnelError ?? VpnTunnelError.startFailed(error.localizedDescription)
            lastError = wrapped.localizedDescription
            throw wrapped
        }
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
    }

    public func remove() async throws {
        guard let manager else { return }
        try await manager.removeFromPreferences()
        self.manager = nil
    }

    private func reloadSavedManager(profileId: String) async throws -> NETunnelProviderManager {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let ghostManagers = ghostStreamManagers(in: all)
        logLoadedManagers(ghostManagers, currentProfileId: profileId)

        if let current = selectStartManager(from: ghostManagers, profileId: profileId) {
            return current
        }

        let foundIds = ghostManagers
            .map { providerProfileId(in: $0) ?? "<missing>" }
            .joined(separator: ", ")
        throw VpnTunnelError.reloadFailed(
            "expected profileId \(profileId), found [\(foundIds)]"
        )
    }

    private func ghostStreamManagers(
        in managers: [NETunnelProviderManager]
    ) -> [NETunnelProviderManager] {
        managers.filter { candidate in
            (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleId
        }
    }

    private func selectManager(
        from managers: [NETunnelProviderManager],
        expectedProfileId: String?
    ) -> NETunnelProviderManager? {
        if let expectedProfileId {
            if let enabledMatch = managers.first(where: {
                $0.isEnabled && providerProfileId(in: $0) == expectedProfileId
            }) {
                return enabledMatch
            }

            if let match = managers.first(where: {
                providerProfileId(in: $0) == expectedProfileId
            }) {
                return match
            }
        }

        return managers.first(where: \.isEnabled) ?? managers.first
    }

    private func selectStartManager(
        from managers: [NETunnelProviderManager],
        profileId: String
    ) -> NETunnelProviderManager? {
        managers.first { $0.isEnabled && providerProfileId(in: $0) == profileId }
            ?? managers.first { providerProfileId(in: $0) == profileId }
    }

    private func providerProfileId(in manager: NETunnelProviderManager) -> String? {
        guard
            let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration
        else { return nil }

        if let profileId = configuration["profileId"] as? String {
            return profileId
        }

        guard let profileData = configuration["profile"] as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(VpnProfile.self, from: profileData).id
    }

    private func logLoadedManagers(
        _ managers: [NETunnelProviderManager],
        currentProfileId: String
    ) {
        if managers.count > 1 {
            log.warning("found \(managers.count, privacy: .public) GhostStream VPN managers")
        }

        for manager in managers {
            let configuredId = providerProfileId(in: manager) ?? "<missing>"
            if configuredId != currentProfileId {
                log.warning(
                    "GhostStream VPN manager profileId=\(configuredId, privacy: .public) will be overwritten with \(currentProfileId, privacy: .public)"
                )
            }
        }
    }
}
