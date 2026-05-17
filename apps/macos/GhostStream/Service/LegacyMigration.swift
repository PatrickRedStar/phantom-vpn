//
//  LegacyMigration.swift
//  GhostStream (macOS)
//
//  IPC-C4 / docs/knowledge/audits/2026-05-17-macos-bug-hunt.md §4
//  Round 3 hardening: OPS-R2-04 / SEC-R2-N01 / CONC-R2-N10 / OPS-R2-03 /
//  SEC-R2-N02 / SEC-R2-N03 — docs/knowledge/audits/2026-05-17-macos-bug-hunt-round2.md
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
//       still points at `com.ghoststream.vpn.tunnel`.
//    6. Posts `LegacyMigration.didFinishKeychainImport` so ProfilesStore
//       (or anything else holding hydrated profile data) can reload after
//       the cert/key items have been re-registered in the new keychain
//       access group.
//    7. Sets the final "completion" flag in the new App Group.
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
import Security
import os.log

public enum LegacyMigration {

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
            return
        }
        if newDefaults.bool(forKey: migrationFlagKey) {
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

        // Snapshot the migrated profile IDs while we're still on the
        // calling thread — phase-B's Keychain importer needs them to
        // target known accounts only (SEC-R2-N03).
        let knownProfileIds = extractProfileIds(from: newDefaults)

        // PHASE B — asynchronous, slow. Detached so UI launch is not
        // blocked by Keychain queries / NE prefs / file I/O
        // (CONC-R2-N10). Final flag flips inside the task so a crash
        // mid-phase-B will cause the slow steps to retry on next launch.
        Task.detached(priority: .userInitiated) { [knownProfileIds] in
            await runPhaseB(profileIds: knownProfileIds)
        }
    }

    private static func runPhaseB(profileIds: [String]) async {
        await migrateAppGroupFilesAsync()
        let importedKeychainItems = await migrateKeychainItemsAsync(profileIds: profileIds)
        await removeStaleVpnManager()

        if importedKeychainItems > 0 {
            // Wake up subscribers (ProfilesStore) on the main thread so
            // they can rehydrate cert/key fields from the new keychain.
            await MainActor.run {
                NotificationCenter.default.post(name: didFinishKeychainImport, object: nil)
            }
        }

        if let newDefaults = UserDefaults(suiteName: newAppGroup) {
            newDefaults.set(true, forKey: migrationFlagKey)
        }
        log.info("v0.23 -> v0.24 legacy migration completed")
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
    private static func extractProfileIds(from defaults: UserDefaults) -> [String] {
        guard let data = defaults.data(forKey: profilesJsonKey) else {
            return []
        }
        // Use a thin local DTO so we don't depend on VpnProfile's full
        // schema — only the `id` field matters here and we want this to
        // be robust to future schema changes.
        struct ProfileIdOnly: Decodable {
            let id: String
        }
        guard let decoded = try? JSONDecoder().decode([ProfileIdOnly].self, from: data) else {
            log.error("profiles.json present but undecodable — no Keychain items will be re-imported")
            return []
        }
        return decoded.map(\.id)
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
            do {
                try await manager.removeFromPreferences()
                log.info("Removed stale NETunnelProviderManager for legacy bundle id")
            } catch {
                log.error("Failed to remove stale NETunnelProviderManager: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
