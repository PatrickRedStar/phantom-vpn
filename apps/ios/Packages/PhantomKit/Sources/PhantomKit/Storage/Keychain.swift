// Keychain — thin SecItem wrapper sharing items across the main app and the
// Packet Tunnel Provider extension via App Group access group.

import Foundation
import Security

/// Namespace for Keychain helpers used by `ProfilesStore` to persist PEM
/// secrets in the shared access group.
///
/// The Xcode project must declare the matching keychain access group on both
/// targets. The signed entitlement includes the Team ID prefix, so we resolve
/// the concrete access group from the running binary instead of hardcoding it.
public enum Keychain {
    /// App Group id used as keychain access group (must match entitlements).
    public static let appGroupIdentifier = "group.com.ghoststream.vpn"
    private static let appIdentifierPrefix = "UPG896A272."

    public static var accessGroup: String {
        resolvedAccessGroup()
    }

    /// Service identifier scoping all GhostStream secrets.
    public static let service = "com.ghoststream.vpn"

    /// Errors raised by this wrapper. `notFound` is reserved for explicit
    /// "key does not exist" semantics in `delete`.
    public enum KeychainError: Error {
        case unhandled(OSStatus)
        case notFound
        case encoding
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

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            addQuery.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    /// Returns the string stored under `key`, or nil if missing or unreadable.
    /// Silently falls back to a non-access-group lookup if the entitlement
    /// is missing.
    public static func get(_ key: String) -> String? {
        func copy(query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item)
        }

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

        var (status, item) = copy(query: query)
        if status == errSecMissingEntitlement {
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            (status, item) = copy(query: query)
        }

        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the item under `key`. `errSecItemNotFound` is swallowed.
    public static func delete(_ key: String) throws {
        let accessGroup = resolvedAccessGroup()
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        applyPlatformOptions(&query)
        var status = SecItemDelete(query as CFDictionary)
        if status == errSecMissingEntitlement {
            query.removeValue(forKey: kSecAttrAccessGroup as String)
            status = SecItemDelete(query as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }
}
