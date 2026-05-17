// Keychain — thin SecItem wrapper sharing items across the main app and the
// Packet Tunnel Provider extension via App Group access group.

import Foundation
import Security
import os.log

/// Namespace for Keychain helpers used by `ProfilesStore` to persist PEM
/// secrets in the shared access group.
///
/// The Xcode project must declare the matching keychain access group on both
/// targets. The signed entitlement includes the Team ID prefix, so we resolve
/// the concrete access group from the running binary instead of hardcoding it.
///
/// SEC-C2: there is **no** fallback to the default user keychain. If the
/// access-group entitlement is missing we refuse to operate, rather than
/// leaking VPN secrets into a world-readable login keychain. The audit
/// (`docs/knowledge/audits/2026-05-17-macos-bug-hunt.md` §SEC-C2) traces the
/// data-loss / privacy implications of the previous behaviour.
public enum Keychain {
    /// App Group id used as keychain access group (must match entitlements).
    public static let appGroupIdentifier = "group.com.ghoststream.client"
    private static let appIdentifierPrefix = "UPG896A272."
    private static let log = Logger(subsystem: "com.ghoststream.client", category: "Keychain")

    public static var accessGroup: String {
        resolvedAccessGroup()
    }

    /// Service identifier scoping all GhostStream secrets.
    public static let service = "com.ghoststream.client"

    /// Errors raised by this wrapper. `notFound` is reserved for explicit
    /// "key does not exist" semantics in `delete`.
    public enum KeychainError: Error {
        case unhandled(OSStatus)
        case notFound
        case encoding
        /// Access-group entitlement is missing. Raised instead of silently
        /// falling back to the default keychain (SEC-C2).
        case missingAccessGroup
    }

    private static func applyPlatformOptions(_ query: inout [String: Any]) {
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
    }

    private static func resolvedAccessGroup() -> String {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "keychain-access-groups" as CFString,
                nil
              )
        else {
            return appGroupIdentifier
        }

        let groups = value as? [String] ?? []
        return groups.first { group in
            group == appGroupIdentifier || group.hasSuffix(".\(appGroupIdentifier)")
        } ?? appGroupIdentifier
        #else
        return appIdentifierPrefix + appGroupIdentifier
        #endif
    }

    /// Stores `value` under `key`. Overwrites any existing item atomically
    /// via delete-then-add (avoids `SecItemUpdate` attribute-mismatch
    /// surprises).
    ///
    /// - Throws: `KeychainError.encoding` if `value` isn't UTF-8 encodable,
    ///   `KeychainError.missingAccessGroup` if the binary is missing its
    ///   access-group entitlement (no fallback — fail closed), or
    ///   `KeychainError.unhandled` on any unexpected SecItem status.
    public static func set(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encoding
        }

        try delete(key)

        let accessGroup = resolvedAccessGroup()
        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        applyPlatformOptions(&addQuery)

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            log.fault(
                "Keychain access-group entitlement missing — refusing to fall back to default keychain (SEC-C2). Item not stored."
            )
            throw KeychainError.missingAccessGroup
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Returns the string stored under `key`, or nil if missing or unreadable.
    ///
    /// SEC-C2: when the access-group entitlement is missing we **do not**
    /// fall back to the default keychain — we log a fault and return nil.
    /// Any previously-leaked secret in the default keychain stays orphaned;
    /// the caller treats this as "no secret" and can re-import.
    public static func get(_ key: String) -> String? {
        let accessGroup = resolvedAccessGroup()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        applyPlatformOptions(&query)

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecMissingEntitlement {
            log.fault(
                "Keychain access-group entitlement missing — refusing to read from default keychain (SEC-C2)."
            )
            return nil
        }

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the item under `key`. `errSecItemNotFound` is swallowed.
    ///
    /// SEC-C2: deletes only target the access-group scope. We will not
    /// attempt to clean up items that may have leaked into the default
    /// keychain in a broken build — that's a one-shot manual recovery the
    /// user has to perform via Keychain Access.
    public static func delete(_ key: String) throws {
        let accessGroup = resolvedAccessGroup()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        applyPlatformOptions(&query)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement {
            log.fault(
                "Keychain access-group entitlement missing — cannot delete \(key, privacy: .public) (SEC-C2)."
            )
            throw KeychainError.missingAccessGroup
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
