//
//  AdminViewModel.swift
//  GhostStream
//
//  ViewModel for the Admin screen. Wraps an `AdminHttpClient` talking to the
//  admin gateway derived from the profile tunnel address, and exposes server-wide
//  client management (list / create / delete / enable / admin-flag /
//  subscription / conn-string).
//
//  TOFU (Trust-On-First-Use) pinning: after the first successful handshake,
//  the observed server-cert SHA-256 is persisted back into the active
//  `VpnProfile.cachedAdminServerCertFp` so subsequent sessions reject any
//  MITM attempt.
//

import Foundation
import Observation
import PhantomKit

/// MainActor-bound observable view model that owns an `AdminHttpClient` for
/// one `VpnProfile`. Re-created when the active profile changes (the profile
/// is `let` on purpose — swap profiles by constructing a new VM).
///
/// All mutating endpoints return only after the server reports success AND a
/// subsequent `refresh()` has completed, so consumers can `await` and see the
/// updated `clients` / `status` state.
@MainActor
@Observable
public final class AdminViewModel {

    // MARK: - Inputs

    /// Profile that owns the admin creds. Captured at init time; swap-by-rebuild.
    public let profile: VpnProfile

    // MARK: - Output state

    /// Latest `/api/status` snapshot, or `nil` before the first successful refresh.
    public private(set) var status: AdminStatus?

    /// Full list of clients from `/api/clients`, most-recent snapshot.
    public private(set) var clients: [AdminClient] = []

    /// `true` while any network task is in flight (list / mutate / fetch).
    public private(set) var loading: Bool = false

    /// Human-readable error for the last failed operation. `nil` on success.
    public private(set) var error: String?

    /// Set to `true` when `AdminHttpClient` couldn't even be constructed
    /// (e.g. Ed25519 client cert rejected). The view shows a persistent banner.
    public private(set) var mtlsUnavailable: Bool = false

    // MARK: - Internals

    private let client: AdminHttpClient?
    private let profilesStore: ProfilesStore

    // MARK: - Init

    /// Construct a VM for `profile`. Builds the `AdminHttpClient` eagerly; if
    /// construction fails (bad PEM, Ed25519-on-iOS, Keychain error) the VM
    /// still exists but `mtlsUnavailable` is `true` and all network ops no-op.
    ///
    /// - Parameters:
    ///   - profile: Profile whose `certPem` / `keyPem` are used for mTLS.
    ///   - profilesStore: Store used to persist the TOFU cert fingerprint
    ///     back to the profile after the first successful handshake.
    public init(profile: VpnProfile, profilesStore: ProfilesStore = .shared) {
        self.profile = profile
        self.profilesStore = profilesStore

        guard
            let certPem = profile.certPem,
            let keyPem = profile.keyPem,
            let baseURL = ProfileEntitlementRefresher.adminBaseURL(for: profile)
        else {
            self.client = nil
            self.mtlsUnavailable = true
            self.error = "Admin-клиент недоступен — отсутствуют сертификаты профиля"
            return
        }

        do {
            self.client = try AdminHttpClient(
                baseURL: baseURL,
                clientCertPem: certPem,
                clientKeyPem: keyPem,
                pinnedServerCertFp: profile.cachedAdminServerCertFp
            )
        } catch {
            self.client = nil
            self.mtlsUnavailable = true
            self.error = (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)
        }
    }

    // MARK: - Queries

    /// Re-fetch `/api/status` and `/api/clients` concurrently. On success,
    /// if we had no pinned fingerprint yet, persists the observed one to the
    /// active profile (TOFU).
    public func refresh() async {
        guard let client else { return }
        loading = true
        error = nil
        defer { loading = false }

        do {
            let selfInfo = try await client.getMe()
            async let statusTask = client.getStatus()
            async let clientsTask = client.listClients()
            let (fetchedStatus, fetchedClients) = try await (statusTask, clientsTask)
            self.status = fetchedStatus
            self.clients = fetchedClients

            // TOFU persistence — only after a successful handshake.
            var updated = profilesStore.profiles.first(where: { $0.id == profile.id }) ?? profile
            updated.cachedIsAdmin = selfInfo.isAdmin
            if let match = fetchedClients.first(where: { ProfileEntitlementRefresher.sameTunIP($0.tunAddr, profile.tunAddr) })
                ?? fetchedClients.first(where: { $0.name == selfInfo.name }) {
                updated.cachedExpiresAt = match.expiresAt
                updated.cachedEnabled = match.enabled
            }
            if let fp = client.lastServerCertFp {
                updated.cachedAdminServerCertFp = fp
            }
            profilesStore.update(updated)
        } catch let err as AdminHttpError {
            self.error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Mutations
    //
    // Each mutation re-runs `refresh()` on success so the UI sees the new
    // state without an extra explicit fetch. Failures bubble up; the caller
    // (view) can surface them however it wants.

    /// `POST /api/clients` — creates a new client. `expiresDays = nil` means
    /// perpetual (mapped to `0` on the wire).
    public func createClient(name: String, expiresDays: Int?, isAdmin: Bool) async throws {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        _ = try await client.createClient(
            name: name,
            expiresDays: expiresDays ?? 0,
            isAdmin: isAdmin
        )
        await refresh()
    }

    /// `DELETE /api/clients/:name`.
    public func deleteClient(name: String) async throws {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        try await client.deleteClient(name: name)
        await refresh()
    }

    /// Flip the `enabled` flag on a client.
    public func setEnabled(name: String, enabled: Bool) async throws {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        if enabled {
            try await client.enableClient(name: name)
        } else {
            try await client.disableClient(name: name)
        }
        await refresh()
    }

    /// Flip the `is_admin` flag on a client.
    public func setAdmin(name: String, isAdmin: Bool) async throws {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        try await client.setAdmin(name: name, isAdmin: isAdmin)
        await refresh()
    }

    /// `POST /api/clients/:name/subscription`.
    /// - Parameters:
    ///   - action: one of `extend` / `set` / `cancel` / `revoke`
    ///   - days: required for `extend`/`set`, ignored otherwise.
    public func manageSubscription(name: String, action: String, days: Int?) async throws {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        try await client.subscription(name: name, action: action, days: days)
        await refresh()
    }

    /// `GET /api/clients/:name/conn_string`.
    public func getConnString(name: String) async throws -> String {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        return try await client.getConnString(name: name)
    }

    /// `GET /api/clients/:name/stats`.
    public func getClientStats(name: String) async throws -> [ClientStat] {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        return try await client.getClientStats(name: name)
    }

    /// `GET /api/clients/:name/logs`.
    public func getClientLogs(name: String) async throws -> [ClientLog] {
        guard let client else { throw AdminHttpError.identityCreation("mTLS client unavailable") }
        return try await client.getClientLogs(name: name)
    }

    // MARK: - Preview seam (DEBUG only)
    //
    // `private(set)` props are file-private for writes, so every
    // preview-state mutator has to live in this file.

    #if DEBUG
    /// Force-set VM state for SwiftUI previews. Do not call from production.
    @MainActor
    func _previewApply(
        status: AdminStatus?,
        clients: [AdminClient],
        error: String?,
        mtls: Bool
    ) {
        self.status = status
        self.clients = clients
        self.error = error
        self.mtlsUnavailable = mtls
        self.loading = false
    }
    #endif
}
