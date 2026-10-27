// ProfileEntitlementRefresher — refreshes the active profile's admin /
// subscription cache through the connected tunnel.
//
// The URLSession admin client itself (AdminHttpClient + DTOs + mTLS/TOFU
// plumbing) lives in PhantomKit (`Sources/PhantomKit/Admin/`) and is shared
// with the macOS app. This file keeps only the iOS-specific refresh glue:
// it depends on VpnStateManager / VpnTunnelController / AppStrings, which
// have per-platform implementations.

import Foundation
import NetworkExtension
import PhantomKit
import os.log

// MARK: - Active profile entitlements

/// Refreshes per-profile admin/subscription cache through the currently
/// connected tunnel. Admin state is identity-specific, so only the active
/// profile is refreshed automatically.
@MainActor
enum ProfileEntitlementRefresher {
    private static let log = Logger(subsystem: "com.ghoststream.client", category: "entitlements")

    static func refreshActiveProfileIfConnected(
        profilesStore: ProfilesStore
    ) async -> VpnProfile? {
        guard let profile = profilesStore.activeProfile else {
            return nil
        }

        let appState = VpnStateManager.shared.state
        if !shouldAttemptRefresh(appState: appState) {
            let systemStatus = await VpnTunnelController().currentStatus()
            guard shouldAttemptRefresh(appState: appState, systemStatus: systemStatus) else {
                return nil
            }
        }

        return await refresh(profile: profile, profilesStore: profilesStore)
    }

    static func shouldAttemptRefresh(
        appState: VpnState,
        systemStatus: NEVPNStatus? = nil
    ) -> Bool {
        if case .disconnecting = appState {
            return false
        }
        switch appState {
        case .connected, .connecting, .reconnecting:
            return true
        case .disconnected, .disconnecting, .error:
            break
        }
        switch systemStatus {
        case .connected, .connecting, .reasserting:
            return true
        case .invalid, .disconnected, .disconnecting, .none:
            return false
        @unknown default:
            return false
        }
    }

    static func refresh(
        profile: VpnProfile,
        profilesStore: ProfilesStore
    ) async -> VpnProfile? {
        guard let certPem = profile.certPem, !certPem.isEmpty,
              let keyPem = profile.keyPem, !keyPem.isEmpty,
              let baseURL = adminBaseURL(for: profile)
        else {
            return nil
        }

        do {
            let client = try AdminHttpClient(
                baseURL: baseURL,
                clientCertPem: certPem,
                clientKeyPem: keyPem,
                pinnedServerCertFp: profile.cachedAdminServerCertFp
            )
            let me = try await client.getMe()
            var updated = currentProfile(for: profile, in: profilesStore)
            me.apply(to: &updated)
            if let fp = client.lastServerCertFp {
                updated.cachedAdminServerCertFp = fp
            }

            profilesStore.update(updated)
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
