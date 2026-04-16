//
//  ClientDetailViewModel.swift
//  GhostStream
//
//  Owns a single `AdminClient`'s detail-view state (stats + logs) and forwards
//  every mutation to the parent `AdminViewModel` so the list, detail view,
//  and server agree on the truth.
//

import Foundation
import Observation

/// MainActor-bound VM for `ClientDetailView`. Holds the latest stats/logs for
/// one client, plus the local "action in progress" flag used to grey out
/// destructive buttons. Mutations flow through `adminVM`, which re-lists
/// clients on success; we then re-fetch stats + logs from the updated state.
@MainActor
@Observable
public final class ClientDetailViewModel {

    // MARK: - Inputs

    /// The current snapshot of this client. Kept in sync with the parent VM's
    /// list by re-reading `adminVM.clients.first(where: { $0.name == name })`
    /// after every mutation.
    public private(set) var client: AdminClient

    /// Per-client RX/TX history samples, newest-last.
    public private(set) var stats: [ClientStat] = []

    /// Destination log rows, newest-last.
    public private(set) var logs: [ClientLog] = []

    /// `true` while fetching stats/logs.
    public private(set) var loading: Bool = false

    /// `true` while a mutation is in flight — disables form buttons.
    public private(set) var mutating: Bool = false

    /// Human-readable error from the last failed op.
    public private(set) var error: String?

    // MARK: - Internals

    private let adminVM: AdminViewModel

    // MARK: - Init

    /// - Parameters:
    ///   - client: initial client snapshot; updated by `syncFromParent`.
    ///   - adminVM: parent admin VM, used for every mutation.
    public init(client: AdminClient, adminVM: AdminViewModel) {
        self.client = client
        self.adminVM = adminVM
    }

    // MARK: - Queries

    /// Fetch stats + logs concurrently.
    public func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let statsTask = adminVM.getClientStats(name: client.name)
            async let logsTask = adminVM.getClientLogs(name: client.name)
            let (s, l) = try await (statsTask, logsTask)
            self.stats = s
            self.logs = l
        } catch let err as AdminHttpError {
            self.error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Pulls the latest `AdminClient` snapshot out of the parent VM's list.
    /// Called after every mutation so the detail view reflects fresh flags.
    private func syncFromParent() {
        if let refreshed = adminVM.clients.first(where: { $0.name == client.name }) {
            self.client = refreshed
        }
    }

    // MARK: - Mutations

    /// Flip `enabled`. Reloads list + local stats/logs on success.
    public func setEnabled(_ enabled: Bool) async {
        await runMutation {
            try await self.adminVM.setEnabled(name: self.client.name, enabled: enabled)
        }
    }

    /// Flip `is_admin`. Reloads list + local stats/logs on success.
    public func setAdmin(_ isAdmin: Bool) async {
        await runMutation {
            try await self.adminVM.setAdmin(name: self.client.name, isAdmin: isAdmin)
        }
    }

    /// Subscription actions — "extend" / "set" / "cancel" / "revoke".
    public func subscription(action: String, days: Int?) async {
        await runMutation {
            try await self.adminVM.manageSubscription(
                name: self.client.name,
                action: action,
                days: days
            )
        }
    }

    /// Delete the client. Reloads list (detail view should pop on success).
    public func delete() async {
        await runMutation {
            try await self.adminVM.deleteClient(name: self.client.name)
        }
    }

    /// Ask the server for the `ghs://` conn string. Doesn't reload — readonly.
    public func getConnString() async -> String? {
        do {
            return try await adminVM.getConnString(name: client.name)
        } catch let err as AdminHttpError {
            self.error = err.errorDescription
            return nil
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    // MARK: - Helpers

    private func runMutation(_ op: @escaping () async throws -> Void) async {
        mutating = true
        error = nil
        defer { mutating = false }
        do {
            try await op()
            syncFromParent()
            await refresh()
        } catch let err as AdminHttpError {
            self.error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Preview seam (DEBUG only)

    #if DEBUG
    /// Force-set VM state for SwiftUI previews. Do not call from production.
    @MainActor
    func _previewApply(stats: [ClientStat], logs: [ClientLog]) {
        self.stats = stats
        self.logs = logs
        self.loading = false
    }
    #endif
}
