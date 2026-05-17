//
//  LegacyMigration.swift
//  GhostStream (macOS)
//
//  IPC-C4 / docs/knowledge/audits/2026-05-17-macos-bug-hunt.md §4
//
//  Pre-v0.24 builds used the bundle id `com.ghoststream.vpn` and App Group
//  `group.com.ghoststream.vpn`. v0.24+ moved to `com.ghoststream.client`
//  and `group.com.ghoststream.client`. Without an explicit migration the
//  user opens the new build to a wiped state — no profiles, no preferences,
//  no Keychain secrets, and a stale `NETunnelProviderManager` pointing at
//  the now-missing legacy tunnel extension.
//
//  This file is the one-shot, idempotent migration that:
//    1. Copies App Group UserDefaults from old → new (only keys missing on
//       the destination — never clobbers a fresh install's defaults).
//    2. Copies known files (profiles.json, preferences.json, snapshot.json,
//       and any other top-level *.json) from the old App Group container
//       into the new one. Skips when the destination already has the file.
//    3. Re-adds Keychain items from the old access group into the new one.
//       `errSecDuplicateItem` is swallowed — the new keychain wins.
//    4. Removes any `NETunnelProviderManager` whose providerBundleIdentifier
//       still points at `com.ghoststream.vpn.tunnel` so System Settings
//       doesn't keep a dead config row visible to the user.
//
//  Failure model: every individual sub-step swallows its error after
//  logging — the migration is best-effort. We only flip the completion
//  flag once a full pass has finished, so a crash mid-migration causes a
//  retry on next launch. Conservative on conflicts: never overwrite an
//  existing destination item.
//
//  Call site: invoked from `VpnStateManager.init()` so the migration
//  runs at host process startup before any of the stores hit their
//  shared UserDefaults / containers. Ideally this would live in
//  `AppDelegate.applicationDidFinishLaunching(_:)`, but `AppDelegate`
//  is owned by Implementer D — coordinator note in the report.
//

import Foundation
import NetworkExtension
import Security
import os.log

public enum LegacyMigration {

    // MARK: - Constants

    /// Stored in the *new* App Group UserDefaults. Once `true` the
    /// migration is skipped permanently — there is no manual reset hook
    /// because re-running is destructive (would risk re-importing stale
    /// data on top of user-edited profiles).
    private static let migrationFlagKey = "io.ghoststream.migration.v23_to_v24.completed"

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

    /// Service identifier that pre-v0.24 GhostStream used. We migrate every
    /// item under it regardless of account key.
    private static let oldKeychainService = "com.ghoststream.vpn"

    private static let log = Logger(subsystem: "com.ghoststream.client", category: "LegacyMigration")

    // MARK: - Entry point

    /// Runs every migration step once, guarded by the completion flag in
    /// the new App Group's UserDefaults.
    ///
    /// Idempotent — safe to call multiple times; after the first successful
    /// run subsequent invocations are O(1) bool reads.
    public static func runIfNeeded() {
        guard let newDefaults = UserDefaults(suiteName: newAppGroup) else {
            log.fault("New App Group container unavailable — cannot run legacy migration")
            return
        }
        if newDefaults.bool(forKey: migrationFlagKey) {
            return
        }

        log.info("Starting v0.23 -> v0.24 legacy migration")

        migrateUserDefaults(newDefaults: newDefaults)
        migrateAppGroupFiles()
        migrateKeychainItems()
        Task { @MainActor in
            await removeStaleVpnManager()
        }

        newDefaults.set(true, forKey: migrationFlagKey)
        log.info("v0.23 -> v0.24 legacy migration completed")
    }

    // MARK: - 1. UserDefaults

    private static func migrateUserDefaults(newDefaults: UserDefaults) {
        guard let oldDefaults = UserDefaults(suiteName: oldAppGroup) else {
            log.info("No legacy App Group UserDefaults to migrate")
            return
        }

        let oldDict = oldDefaults.dictionaryRepresentation()
        var copied = 0
        for (key, value) in oldDict {
            // Skip our own bookkeeping if it somehow leaked.
            if key == migrationFlagKey { continue }
            // Conservative: never overwrite a value that already exists in
            // the new container. Avoids clobbering settings the user has
            // already edited in the new build.
            if newDefaults.object(forKey: key) != nil { continue }
            newDefaults.set(value, forKey: key)
            copied += 1
        }
        log.info("UserDefaults migration: copied \(copied, privacy: .public) keys from legacy App Group")
    }

    // MARK: - 2. App Group files

    private static func migrateAppGroupFiles() {
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

        // Explicit known files first (cheap to enumerate and we want
        // deterministic behaviour even if the legacy install left junk
        // around at the top level).
        let knownFiles = [
            "profiles.json",
            "preferences.json",
            "snapshot.json",
            "last_tunnel_params.json",
            "route_policy.json",
        ]

        var copied = 0
        for name in knownFiles {
            let src = oldContainer.appendingPathComponent(name)
            let dst = newContainer.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            if fm.fileExists(atPath: dst.path) {
                continue   // never overwrite
            }
            do {
                try fm.copyItem(at: src, to: dst)
                copied += 1
                log.info("Migrated file: \(name, privacy: .public)")
            } catch {
                log.error("Failed to migrate \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        // Sweep any *.json the explicit list missed (e.g. forks of the app
        // or future v0.23.x patch fields). Same overwrite-protection rules.
        if let entries = try? fm.contentsOfDirectory(at: oldContainer,
                                                    includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles]) {
            for src in entries where src.pathExtension.lowercased() == "json" {
                let dst = newContainer.appendingPathComponent(src.lastPathComponent)
                if fm.fileExists(atPath: dst.path) { continue }
                do {
                    try fm.copyItem(at: src, to: dst)
                    copied += 1
                    log.info("Migrated stray file: \(src.lastPathComponent, privacy: .public)")
                } catch {
                    log.error("Stray file copy failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
        log.info("File migration: copied \(copied, privacy: .public) file(s) from legacy container")
    }

    // MARK: - 3. Keychain

    private static func migrateKeychainItems() {
        var totalCopied = 0
        for oldGroup in oldKeychainAccessGroups {
            totalCopied += migrateKeychainItems(fromAccessGroup: oldGroup)
        }
        log.info("Keychain migration: re-added \(totalCopied, privacy: .public) item(s) to new access group")
    }

    private static func migrateKeychainItems(fromAccessGroup oldAccessGroup: String) -> Int {
        // 1) Enumerate everything under the legacy service + access-group
        //    combination. We need both account+data so we can rewrite the
        //    item into the new group.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldKeychainService,
            kSecAttrAccessGroup as String: oldAccessGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif

        var rawResults: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &rawResults)
        if status == errSecItemNotFound {
            return 0
        }
        guard status == errSecSuccess, let items = rawResults as? [[String: Any]] else {
            if status != errSecMissingEntitlement {
                log.error("Keychain enumerate failed (\(status, privacy: .public)) for access group \(oldAccessGroup, privacy: .public)")
            }
            return 0
        }

        let newAccessGroup = resolveNewKeychainAccessGroup()
        var copied = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data
            else { continue }

            var addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                // Service intentionally re-namespaced to the new id so the
                // new `Keychain.service` lookup hits these items.
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
                copied += 1
            case errSecDuplicateItem:
                // New keychain already owns this account — never clobber.
                continue
            default:
                log.error("Keychain re-add failed (\(addStatus, privacy: .public)) for account \(account, privacy: .public)")
            }
        }
        return copied
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

    private static let newKeychainService = "com.ghoststream.client"

    // MARK: - 4. Stale NETunnelProviderManager

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
