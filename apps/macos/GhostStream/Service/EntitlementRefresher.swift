//
//  EntitlementRefresher.swift
//  GhostStream (macOS)
//
//  Background refresh of the active profile's admin / subscription cache
//  (`cachedIsAdmin`, `cachedExpiresAt`, `cachedEnabled`, TOFU cert pin)
//  through the connected tunnel via `/api/me`. This is what makes the ADMIN
//  sidebar tab appear for admin identities without the user ever having
//  opened it — the AdminViewModel does the same persistence when the tab
//  itself is used.
//
//  macOS twin of the iOS `ProfileEntitlementRefresher`; the polling shape
//  differs because the macOS host has no per-view refresh cadence to
//  piggyback on (menu-bar popover may never be opened).
//

import Foundation
import PhantomKit
import os.log

@MainActor
final class EntitlementRefresher {

    static let shared = EntitlementRefresher()

    private let log = Logger(subsystem: "com.ghoststream.client", category: "entitlements")
    private var loopTask: Task<Void, Never>?
    private var lastAttemptAt: Date?
    private var lastAttemptProfileId: String?

    private init() {}

    /// Idempotent — called once from `AppDelegate.applicationDidFinishLaunching`.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }

    private func tick() async {
        guard VpnStateManager.shared.statusFrame.state == .connected else { return }

        let store = ProfilesStore.shared
        guard let profile = store.activeProfile,
              let certPem = profile.certPem, !certPem.isEmpty,
              let keyPem = profile.keyPem, !keyPem.isEmpty,
              let baseURL = AdminGateway.adminBaseURL(for: profile)
        else { return }

        // Once per 5 minutes per profile is plenty: `is_admin` and the
        // subscription change rarely, and the ADMIN tab refreshes the same
        // cache on its own when open.
        // Failures share the same backoff so an unreachable gateway is not
        // hammered every 20s tick.
        if lastAttemptProfileId == profile.id,
           let last = lastAttemptAt,
           Date().timeIntervalSince(last) < 300 {
            return
        }
        lastAttemptAt = Date()
        lastAttemptProfileId = profile.id

        do {
            let client = try AdminHttpClient(
                baseURL: baseURL,
                clientCertPem: certPem,
                clientKeyPem: keyPem,
                pinnedServerCertFp: profile.cachedAdminServerCertFp
            )
            let me = try await client.getMe()

            var updated = store.profiles.first(where: { $0.id == profile.id }) ?? profile
            updated.certPem = updated.certPem ?? certPem
            updated.keyPem = updated.keyPem ?? keyPem
            me.apply(to: &updated)
            if let fp = client.lastServerCertFp {
                updated.cachedAdminServerCertFp = fp
            }

            store.update(updated)
            log.info("entitlements refreshed profile=\(profile.id, privacy: .public) is_admin=\(me.isAdmin)")
        } catch {
            log.debug("entitlement refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
