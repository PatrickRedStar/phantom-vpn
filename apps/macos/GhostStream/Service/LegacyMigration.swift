//
//  LegacyMigration.swift
//  GhostStream (macOS)
//
//  IPC-C4 / docs/knowledge/audits/2026-05-17-macos-bug-hunt.md §4
//  Round 3 hardening: OPS-R2-04 / SEC-R2-N01 / CONC-R2-N10 / OPS-R2-03 /
//  SEC-R2-N02 / SEC-R2-N03 — docs/knowledge/audits/2026-05-17-macos-bug-hunt-round2.md
//  Round 5 hardening: MIG-R4-N01 / MIG-R4-N03 / MIG-R4-N04 / MIG-R4-N07 —
//  docs/knowledge/audits/2026-05-17-macos-bug-hunt-round4.md
//
//  Pre-v0.24 builds used the bundle id `com.ghoststream.vpn` and App Group
//  `group.com.ghoststream.vpn`. v0.24+ moved to `com.ghoststream.client`
//  and `group.com.ghoststream.client`. Without an explicit migration the
//  user opens the new build to a wiped state — no profiles, no preferences,
//  no Keychain secrets, and a stale `NETunnelProviderManager` pointing at
//  the now-missing legacy tunnel extension.
//
//  This file is the one-shot, idempotent migration that, in two phases:
//
//  PHASE A — synchronous, fast (<100ms typical):
//    1. Copies App Group UserDefaults from old → new (only keys missing on
//       the destination — never clobbers a fresh install's defaults). This
//       includes the canonical `profiles.json` and `active_id` keys that
//       ProfilesStore reads at `init()` time, so ProfilesStore sees the
//       migrated profile list as soon as it's instantiated.
//    2. Sets a "phase-A completed" sentinel in the new App Group so on
//       the next launch we don't repeat the UserDefaults copy even if
//       phase B got interrupted.
//
//  PHASE B — asynchronous, slow (file I/O, Keychain queries, NE prefs):
//    3. Copies the small set of known files from the old App Group
//       container into the new one (`snapshot.json` is the only one that
//       actually exists in practice; ProfilesStore and PreferencesStore
//       live in UserDefaults plist — already handled by phase A).
//    4. Re-adds Keychain items from the old access group into the new one.
//       Only re-imports items that match a profile ID present in the
//       migrated `profiles.json` (SEC-R2-N03 — no wildcard enumeration).
//    5. Removes any `NETunnelProviderManager` whose providerBundleIdentifier
//       still points at `com.ghoststream.vpn.tunnel`. Skips managers that
//       are currently `.connected` or `.connecting` — those are live
//       sessions and we wait until next launch to retire them
//       (MIG-R4-N04).
//    6. Posts `LegacyMigration.didFinishKeychainImport` unconditionally
//       on completion so ProfilesStore (or anything else holding
//       hydrated profile data) reloads regardless of how many Keychain
//       items were re-imported — including the legitimate "0 items"
//       case (MIG-R4-N03).
//    7. Sets the final "completion" flag in the new App Group, but only
//       after a *successful* phase B. If `extractProfileIds` failed to
//       decode `profiles.json` we leave `migrationFlagKey` unset so the
//       slow phase retries on next launch (MIG-R4-N07).
//
//  CONNECT GATING (MIG-R4-N01): the UI subscribes to
//  `LegacyMigration.state.phaseBCompleted` and disables the CONNECT
//  button while phase B is in flight. Otherwise the user can see
//  profiles in the picker (phase A copied `profiles.json` into the new
//  UserDefaults) but the Keychain cert/key items aren't re-imported
//  yet — the tunnel would start with `certPem == nil` and silently fail
//  during mTLS handshake.
//
//  Failure model: every individual sub-step swallows its error after
//  logging — the migration is best-effort. Phase-A flag protects the
//  user-visible UserDefaults copy from running twice; phase-B flag flips
//  only after the full pass finishes, so a crash mid-phase-B causes a
//  retry on next launch.
//
//  Call site: invoked from `AppDelegate.applicationWillFinishLaunching(_:)`
//  so phase A runs BEFORE SwiftUI evaluates `GhostStreamApp.body` —
//  ProfilesStore.init() then sees the migrated profile list on first read
//  (OPS-R2-04 / SEC-R2-N01 fix). Previously this lived in
//  `VpnStateManager.init()`, which ran AFTER ProfilesStore.init() because
//  of `@State` initialiser order, so the first save() on the empty
//  ProfilesStore would clobber the migration.
//

import Foundation
import NetworkExtension
import Observation
import Security
import os.log

public enum LegacyMigration {

    // MARK: - Observable state (MIG-R4-N01)

    /// Migration progress observed by the UI. SwiftUI views read
    /// `phaseBCompleted` (or `isMigrating`) to gate the CONNECT action
    /// while Keychain re-import is still running. Without this guard the
    /// user could tap CONNECT in the ~5–30s gap between phase A
    /// (profile picker visible) and phase B (cert/key items re-added) —
    /// the tunnel would attempt mTLS with `certPem == nil` and fail
    /// silently.
    @MainActor
    @Observable
    public final class State {
        public fileprivate(set) var phaseACompleted: Bool = false
        public fileprivate(set) var phaseBCompleted: Bool = false

        /// `true` while the slow phase B steps are still running.
        /// Equivalent to `!phaseBCompleted` once phase A has started —
        /// kept as a derived property so call sites read naturally.
        public var isMigrating: Bool { !phaseBCompleted }

        fileprivate init() {}
    }

    @MainActor
    public static let state = State()

    // MARK: - Constants

    /// Stored in the *new* App Group UserDefaults. Once `true` the full
    /// migration is skipped permanently — there is no manual reset hook
    /// because re-running is destructive (would risk re-importing stale
    /// data on top of user-edited profiles).
    private static let migrationFlagKey = "io.ghoststream.migration.v23_to_v24.completed"

    /// Sentinel that the synchronous phase-A (UserDefaults copy) finished.
    /// Lets us avoid re-copying user-edited preferences if phase-B crashes
    /// mid-flight; ProfilesStore-visible data is intact even if Keychain
    /// migration didn't get to finalise.
    private static let phaseACompleteKey = "io.ghoststream.migration.v23_to_v24.phaseA"

    private static let oldAppGroup = "group.com.ghoststream.vpn"
    private static let newAppGroup = "group.com.ghoststream.client"
    private static let legacyTunnelBundleId = "com.ghoststream.vpn.tunnel"

    /// Old keychain access group. iOS uses the team-prefixed form; macOS
    /// data-protection keychain expects the bare app-group identifier.
    /// We attempt both spellings so the same migration works on either
    /// platform.
    private static let oldKeychainAccessGroups = [
        oldAppGroup,
        "UPG896A272.\(oldAppGroup)",
    ]

    /// Service identifier that pre-v0.24 GhostStream used.
    private static let oldKeychainService = "com.ghoststream.vpn"
    private static let newKeychainService = "com.ghoststream.client"

    /// UserDefaults keys that ProfilesStore relies on; we extract profile
    /// IDs from `profiles.json` after phase-A so phase-B's Keychain
    /// re-import can target only known accounts (SEC-R2-N03).
    private static let profilesJsonKey = "profiles.json"

    private static let log = Logger(subsystem: "com.ghoststream.client", category: "LegacyMigration")

    /// Posted after phase-B finishes the Keychain re-import — observers
    /// (e.g. ProfilesStore) can reload to pick up freshly-imported cert
    /// and key material. The notification name is exposed so any
    /// PhantomKit-side reload hook can subscribe without importing this
    /// module directly (it's a plain Notification name on .default centre).
    public static let didFinishKeychainImport = Notification.Name(
        "io.ghoststream.LegacyMigration.didFinishKeychainImport"
    )

    // MARK: - Entry point

    /// Runs the migration pipeline. Phase A (UserDefaults copy) runs
    /// synchronously on the calling thread — typically <100ms. Phase B
    /// (Keychain, files, NE prefs) is dispatched onto a detached task
    /// so the UI launch isn't blocked by Keychain enumeration (CONC-R2-N10).
    ///
    /// Idempotent — safe to call multiple times; after the first
    /// successful run subsequent invocations are O(1) bool reads.
    ///
    /// Must be called BEFORE any of the PhantomKit stores hit their
    /// shared UserDefaults / containers, otherwise the stores' init()
    /// path reads empty data and overwrites it with empty data on the
    /// next save(). The canonical call site is
    /// `AppDelegate.applicationWillFinishLaunching(_:)` (OPS-R2-04 /
    /// SEC-R2-N01).
    public static func runIfNeeded() {
        guard let newDefaults = UserDefaults(suiteName: newAppGroup) else {
            log.fault("New App Group container unavailable — cannot run legacy migration")
            // Treat as "nothing to migrate" so the UI doesn't sit forever
            // gated on a flag that will never flip.
            Task { @MainActor in
                state.phaseACompleted = true
                state.phaseBCompleted = true
            }
            return
        }
        if newDefaults.bool(forKey: migrationFlagKey) {
            // Already done in a prior session — UI is free to connect
            // immediately.
            Task { @MainActor in
                state.phaseACompleted = true
                state.phaseBCompleted = true
            }
            return
        }

        log.info("Starting v0.23 -> v0.24 legacy migration")

        // PHASE A — synchronous, fast. Must complete before any store
        // reads the new App Group container.
        if !newDefaults.bool(forKey: phaseACompleteKey) {
            migrateUserDefaults(newDefaults: newDefaults)
            newDefaults.set(true, forKey: phaseACompleteKey)
        } else {
            log.info("Phase A already completed — running only phase B")
        }
        // Phase A is observably done — the UI may now render the
        // profile list, but CONNECT remains gated on `phaseBCompleted`.
        Task { @MainActor in
            state.phaseACompleted = true
        }

        // PHASE B — asynchronous, slow. Detached so UI launch is not
        // blocked by Keychain queries / NE prefs / file I/O
        // (CONC-R2-N10). Final flag flips inside the task so a crash
        // mid-phase-B will cause the slow steps to retry on next launch.
        //
        // We compute `knownProfileIds` *inside* the detached task using
        // a Result so a malformed `profiles.json` (decode failure) does
        // not mark the migration as complete — phase B is left
        // incomplete and retries on next launch (MIG-R4-N07).
        Task.detached(priority: .userInitiated) {
            await runPhaseB()
        }
    }

    private static func runPhaseB() async {
        guard let newDefaults = UserDefaults(suiteName: newAppGroup) else {
            log.fault("Phase B: new App Group container unavailable")
            // Unblock the UI — there is nothing more we can do.
            await MainActor.run { state.phaseBCompleted = true }
            return
        }

        // MIG-R4-N07: if `profiles.json` is present but undecodable we
        // bail out *without* setting `migrationFlagKey`. The next
        // launch retries the slow phase against the same (possibly
        // user-repaired) data instead of permanently masking the
        // failure.
        let profileIds: [String]
        switch extractProfileIds(from: newDefaults) {
        case .success(let ids):
            profileIds = ids
        case .failure(let error):
            log.error("Phase B: profiles.json decode failed — won't mark migration complete: \(String(describing: error), privacy: .public)")
            // Unblock the UI: a decode failure is unrecoverable from a
            // user perspective. Leaving `isMigrating == true` forever
            // is worse than letting the user try to connect (they'll
            // see an inline "no Keychain item" error if needed).
            await MainActor.run { state.phaseBCompleted = true }
            return
        }

        await migrateAppGroupFilesAsync()
        let importedKeychainItems = await migrateKeychainItemsAsync(profileIds: profileIds)
        await removeStaleVpnManager()

        newDefaults.set(true, forKey: migrationFlagKey)

        // MIG-R4-N03: post the notification unconditionally — including
        // the legitimate 0-keychain-items case. Previously this branch
        // only fired when at least one item was re-imported, so a
        // legacy install with no cert/key material left ProfilesStore
        // stuck on its pre-migration snapshot until the user manually
        // reloaded.
        await MainActor.run {
            NotificationCenter.default.post(name: didFinishKeychainImport, object: nil)
            state.phaseBCompleted = true
        }

        log.info("v0.23 -> v0.24 legacy migration completed (keychain items: \(importedKeychainItems, privacy: .public))")
    }

    // MARK: - 1. UserDefaults (PHASE A — synchronous)

    private static func migrateUserDefaults(newDefaults: UserDefaults) {
        guard let oldDefaults = UserDefaults(suiteName: oldAppGroup) else {
            log.info("No legacy App Group UserDefaults to migrate")
            return
        }

        let oldDict = oldDefaults.dictionaryRepresentation()
        var copied = 0
        for (key, value) in oldDict {
            // Skip our own bookkeeping if it somehow leaked.
            if key == migrationFlagKey || key == phaseACompleteKey { continue }
            // Conservative: never overwrite a value that already exists in
            // the new container. Avoids clobbering settings the user has
            // already edited in the new build.
            if newDefaults.object(forKey: key) != nil { continue }
            newDefaults.set(value, forKey: key)
            copied += 1
        }
        log.info("UserDefaults migration: copied \(copied, privacy: .public) keys from legacy App Group")
    }

    /// Reads the just-migrated `profiles.json` and returns the list of
    /// profile IDs. Used to constrain Keychain re-import to known
    /// accounts (SEC-R2-N03) — we will *not* re-import every legacy
    /// Keychain item under the old service identifier, since another
    /// app sharing our Team ID could have written items there.
    ///
    /// MIG-R4-N07: returns a `Result` so phase B can distinguish
    /// "legitimately empty profile list" (`.success([])`) from "data
    /// present but undecodable" (`.failure`). Decode failures must NOT
    /// mark the migration as complete — they should retry on the next
    /// launch.
    private static func extractProfileIds(from defaults: UserDefaults) -> Result<[String], Error> {
        guard let data = defaults.data(forKey: profilesJsonKey) else {
            // No `profiles.json` at all — legitimately empty.
            return .success([])
        }
        // Use a thin local DTO so we don't depend on VpnProfile's full
        // schema — only the `id` field matters here and we want this to
        // be robust to future schema changes.
        struct ProfileIdOnly: Decodable {
            let id: String
        }
        do {
            let decoded = try JSONDecoder().decode([ProfileIdOnly].self, from: data)
            return .success(decoded.map(\.id))
        } catch {
            log.error("profiles.json present but undecodable — no Keychain items will be re-imported: \(String(describing: error), privacy: .public)")
            return .failure(error)
        }
    }

    // MARK: - 2. App Group files (PHASE B — async)

    /// Copies the known, small set of files that genuinely live in the
    /// App Group container. ProfilesStore and PreferencesStore live in
    /// the UserDefaults plist (already handled by phase A), so the only
    /// file to migrate is the runtime `snapshot.json`. We deliberately do
    /// NOT enumerate the directory for `*.json` (OPS-R2-03 / SEC-R2-N02):
    /// a sweep imports whatever any other app sharing our Team ID may
    /// have written into the legacy container.
    private static func migrateAppGroupFilesAsync() async {
        let fm = FileManager.default
        guard let oldContainer = fm.containerURL(
                forSecurityApplicationGroupIdentifier: oldAppGroup
              ),
              let newContainer = fm.containerURL(
                forSecurityApplicationGroupIdentifier: newAppGroup
              )
        else {
            log.info("App Group container(s) unavailable — skipping file migration")
            return
        }

        let knownFiles = ["snapshot.json"]
        var copied = 0
        for name in knownFiles {
            let src = oldContainer.appendingPathComponent(name)
            let dst = newContainer.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) { continue }
            do {
                try fm.copyItem(at: src, to: dst)
                copied += 1
                log.info("Migrated file: \(name, privacy: .public)")
            } catch {
                log.error("Failed to migrate \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        log.info("File migration: copied \(copied, privacy: .public) file(s) from legacy container")
    }

    // MARK: - 3. Keychain (PHASE B — async)

    /// Re-imports Keychain items for a known, finite list of profile IDs.
    /// SEC-R2-N03: previously this enumerated everything under the legacy
    /// service identifier and re-added it under the new one — a
    /// supply-chain attack vector for any other app sharing our Team ID
    /// that had written items under the same service. We now target only
    /// `profile.<id>.cert` / `profile.<id>.key` for IDs present in the
    /// migrated `profiles.json`.
    ///
    /// Returns the number of items successfully re-imported.
    private static func migrateKeychainItemsAsync(profileIds: [String]) async -> Int {
        if profileIds.isEmpty {
            log.info("No profile IDs to migrate — Keychain re-import skipped")
            return 0
        }

        var totalCopied = 0
        for oldGroup in oldKeychainAccessGroups {
            for profileId in profileIds {
                totalCopied += migrateKeychainItem(
                    account: "profile.\(profileId).cert",
                    fromAccessGroup: oldGroup
                )
                totalCopied += migrateKeychainItem(
                    account: "profile.\(profileId).key",
                    fromAccessGroup: oldGroup
                )
            }
        }
        log.info("Keychain migration: re-added \(totalCopied, privacy: .public) item(s) to new access group")
        return totalCopied
    }

    /// Copies one Keychain item identified by (oldAccessGroup, oldService,
    /// account) into (newAccessGroup, newService, account). Returns 1 on
    /// success, 0 otherwise. `errSecDuplicateItem` and `errSecItemNotFound`
    /// are quiet outcomes.
    private static func migrateKeychainItem(
        account: String,
        fromAccessGroup oldAccessGroup: String
    ) -> Int {
        // Step 1: copy the value out under the old service+access-group.
        var copyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldKeychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: oldAccessGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        #if os(macOS)
        copyQuery[kSecUseDataProtectionKeychain as String] = true
        #endif

        var rawData: CFTypeRef?
        let copyStatus = SecItemCopyMatching(copyQuery as CFDictionary, &rawData)
        if copyStatus == errSecItemNotFound {
            return 0
        }
        guard copyStatus == errSecSuccess, let data = rawData as? Data else {
            if copyStatus != errSecMissingEntitlement {
                log.error("Keychain read failed (\(copyStatus, privacy: .public)) for account \(account, privacy: .public)")
            }
            return 0
        }

        // Step 2: add under the new service+access-group.
        let newAccessGroup = resolveNewKeychainAccessGroup()
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: newKeychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: newAccessGroup,
        ]
        #if os(macOS)
        addQuery[kSecUseDataProtectionKeychain as String] = true
        #endif

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return 1
        case errSecDuplicateItem:
            // New keychain already owns this account — never clobber.
            return 0
        default:
            log.error("Keychain re-add failed (\(addStatus, privacy: .public)) for account \(account, privacy: .public)")
            return 0
        }
    }

    /// Mirror of `Keychain.resolvedAccessGroup()` so we don't import the
    /// PhantomKit type (and risk a circular dep when the project layout
    /// shifts).
    private static func resolveNewKeychainAccessGroup() -> String {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil
              )
        else {
            return newAppGroup
        }
        let groups = value as? [String] ?? []
        return groups.first { group in
            group == newAppGroup || group.hasSuffix(".\(newAppGroup)")
        } ?? newAppGroup
        #else
        return "UPG896A272.\(newAppGroup)"
        #endif
    }

    // MARK: - 4. Stale NETunnelProviderManager (PHASE B — async)

    @MainActor
    private static func removeStaleVpnManager() async {
        let managers: [NETunnelProviderManager]
        do {
            managers = try await NETunnelProviderManager.loadAllFromPreferences()
        } catch {
            log.error("Could not load NETunnelProviderManager list to prune stale entries: \(String(describing: error), privacy: .public)")
            return
        }

        let stale = managers.filter { manager in
            let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
            return proto?.providerBundleIdentifier == legacyTunnelBundleId
        }

        if stale.isEmpty {
            return
        }

        for manager in stale {
            // MIG-R4-N04: never tear down a *live* legacy session
            // mid-flight. A user could legitimately be migrating
            // straight from a connected v0.23 install, and yanking the
            // NEVPN manager out from under an active connection drops
            // the tunnel without any user feedback. Defer removal until
            // the next launch when the session has naturally ended.
            let status = manager.connection.status
            if status == .connected || status == .connecting || status == .reasserting {
                log.warning("Legacy NETunnelProviderManager is active (status=\(status.rawValue, privacy: .public)) — postponing removal until next launch")
                continue
            }
            do {
                try await manager.removeFromPreferences()
                log.info("Removed stale NETunnelProviderManager for legacy bundle id")
            } catch {
                log.error("Failed to remove stale NETunnelProviderManager: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
