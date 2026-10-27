// ProfileEntitlementRefresher — refreshes the active profile's admin /
// subscription cache through the connected tunnel.
//
// The URLSession admin client itself (AdminHttpClient + DTOs + mTLS/TOFU
// plumbing) lives in PhantomKit (`Sources/PhantomKit/Admin/`) and is shared
// with the macOS app. This file keeps only the iOS-specific refresh glue:
// it depends on VpnStateManager / SystemSurfaces / AppStrings, which have
// per-platform implementations.

import Foundation
import PhantomKit
import os.log
import UIKit

// MARK: - Active profile entitlements

/// Refreshes per-profile admin/subscription cache through the currently
/// connected tunnel. Admin state is identity-specific, so only the active
/// profile is refreshed automatically.
///
/// Safe to call as often as a caller likes: one request at a time, only in
/// the foreground while connected, at most every 5 min per profile (sooner
/// for a new tunnel session), failures back off from 30 s to 5 min.
@MainActor
enum ProfileEntitlementRefresher {
    private static let log = Logger(subsystem: "com.ghoststream.client", category: "entitlements")
    private static let interval: TimeInterval = 300

    private static var inFlight: Task<VpnProfile?, Never>?
    private static var last: (key: String, session: Date?, at: Date, ok: Bool, failures: Int)?

    static func refreshActiveProfileIfConnected(
        profilesStore: ProfilesStore
    ) async -> VpnProfile? {
        guard let profile = profilesStore.activeProfile,
              UIApplication.shared.applicationState == .active,
              shouldAttemptRefresh(appState: VpnStateManager.shared.state)
        else {
            return nil
        }
        if let inFlight {
            return await inFlight.value
        }

        let key = profile.id + (profile.certPem ?? "")
        let session = SystemSurfaces.sessionStartedAt()
        if let last, last.key == key, session == nil || session == last.session {
            let wait = last.ok ? interval : min(interval, 30 * pow(2, Double(last.failures - 1)))
            if Date().timeIntervalSince(last.at) < wait {
                return last.ok ? profile : nil
            }
        }

        let task = Task { await refresh(profile: profile, profilesStore: profilesStore) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        let failures = result != nil ? 0 : (last?.key == key ? last?.failures ?? 0 : 0) + 1
        last = (key, session, Date(), result != nil, failures)
        return result
    }

    /// The admin API is reachable only through an established tunnel.
    static func shouldAttemptRefresh(appState: VpnState) -> Bool {
        if case .connected = appState { return true }
        return false
    }

    static func refresh(
        profile: VpnProfile,
        profilesStore: ProfilesStore
    ) async -> VpnProfile? {
        do {
            let client = try AdminHttpClient.shared(for: profile)
            let me = try await client.getMe()
            let current = currentProfile(for: profile, in: profilesStore)
            var updated = current
            me.apply(to: &updated)
            if let fp = client.lastServerCertFp {
                updated.cachedAdminServerCertFp = fp
            }

            if updated != current { profilesStore.update(updated) }
            return updated
        } catch {
            log.error("Admin entitlement refresh failed for profile \(profile.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func adminBaseURL(for profile: VpnProfile) -> URL? {
        URL(string: "https://\(gatewayHost(forTunAddr: profile.tunAddr)):8080")
    }

    static func gatewayHost(forTunAddr tunAddr: String) -> String {
        AdminGateway.host(forTunAddr: tunAddr)
    }

    static func subscriptionText(for profile: VpnProfile) -> String? {
        guard profile.cachedEnabled != false else {
            return AppStrings.localized("dashboard.subscription.client_disabled", fallback: "Client disabled")
        }
        guard let expiresAt = profile.cachedExpiresAt else {
            return profile.cachedEnabled != nil
                ? AppStrings.localized("dashboard.subscription.unlimited", fallback: "Unlimited subscription")
                : nil
        }
        let remaining = expiresAt - Int64(Date().timeIntervalSince1970)
        guard remaining > 0 else {
            return AppStrings.localized("dashboard.subscription.expired", fallback: "Subscription expired")
        }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        if days > 0 {
            return String(
                format: AppStrings.localized(
                    "native.dashboard.subscription.remaining.format",
                    fallback: "Subscription: %lldd %lldh"
                ),
                days,
                hours
            )
        }
        if hours > 0 {
            return String(
                format: AppStrings.localized(
                    "native.dashboard.subscription.hours.format",
                    fallback: "Subscription: %lldh"
                ),
                hours
            )
        }
        return AppStrings.localized(
            "native.dashboard.subscription.less_than_hour",
            fallback: "Subscription: < 1h"
        )
    }

    private static func currentProfile(
        for profile: VpnProfile,
        in profilesStore: ProfilesStore
    ) -> VpnProfile {
        var current = profilesStore.profiles.first(where: { $0.id == profile.id }) ?? profile
        current.certPem = current.certPem ?? profile.certPem
        current.keyPem = current.keyPem ?? profile.keyPem
        return current
    }
}
