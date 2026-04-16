// ProfilesStore — singleton, observable VPN-profile repository.
// Metadata lives in App Group UserDefaults; PEM secrets live in the shared
// Keychain access group so the Packet Tunnel Provider can hydrate them.

import Foundation
import Observation
import os.log

/// Singleton store for VPN profiles. Backed by App Group UserDefaults for
/// metadata (name, server address, tun address, etc.) and the shared
/// Keychain for the PEM secrets (cert chain + private key).
///
/// Main-actor bound: mutation and observation always happen on the main
/// thread. I/O is small-volume (single JSON blob + a handful of Keychain
/// items) and runs synchronously.
@MainActor
@Observable
public final class ProfilesStore {

    /// Process-wide shared instance.
    public static let shared = ProfilesStore()

    // MARK: - State

    /// All known profiles. Mutate only through the public API — the observers
    /// trigger UI re-render when the array or its contents change.
    public private(set) var profiles: [VpnProfile] = []

    /// Id of the currently active profile, if any.
    public private(set) var activeId: String?

    // MARK: - Storage

    private let defaults: UserDefaults
    private let profilesKey = "profiles.json"
    private let activeIdKey = "active_id"
    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "ProfilesStore")

    private init() {
        // App Group UserDefaults must be configured — otherwise main app
        // and extension can't agree on stored state.
        self.defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")!
        load()
    }

    // MARK: - Derived

    /// First match by `activeId`, falling back to the first profile if
    /// the id doesn't resolve (stale id).
    public var activeProfile: VpnProfile? {
        if let activeId, let match = profiles.first(where: { $0.id == activeId }) {
            return match
        }
        return profiles.first
    }

    /// Returns the profile with the given id, with PEM secrets hydrated from
    /// the Keychain. Returns nil if no profile with that id exists.
    public func load(id: String) -> VpnProfile? {
        profiles.first(where: { $0.id == id })
    }

    // MARK: - Mutations

    /// Appends a new profile. If no profile is active, activates it.
    public func add(_ profile: VpnProfile) {
        profiles.append(profile)
        if activeId == nil { activeId = profile.id }
        save()
    }

    /// Replaces the profile with the same id. No-op if not found.
    public func update(_ profile: VpnProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        save()
    }

    /// Removes the profile and its Keychain secrets. Clears `activeId`
    /// if it pointed at the removed profile.
    public func remove(id: String) {
        profiles.removeAll { $0.id == id }
        deleteKeychainSecrets(profileId: id)
        if activeId == id { activeId = profiles.first?.id }
        save()
    }

    /// Sets the active profile by id. Silently ignored if the id is
    /// unknown.
    public func setActive(id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeId = id
        save()
    }

    /// Parses a `ghs://` conn string via the Rust bridge and inserts the
    /// resulting profile. Returns the newly-added profile.
    /// - Throws: `ConnStringError.invalid` on parse failure.
    @discardableResult
    public func importFromConnString(_ input: String) throws -> VpnProfile {
        guard let parsed = PhantomBridge.parseConnString(input) else {
            throw ConnStringError.invalid
        }
        let profile = VpnProfile(
            serverAddr: parsed.serverAddr,
            serverName: parsed.serverName,
            insecure: false,
            certPem: parsed.certPem,
            keyPem: parsed.keyPem,
            tunAddr: parsed.tunAddr
        )
        add(profile)
        return profile
    }

    /// Errors from `importFromConnString`.
    public enum ConnStringError: Error { case invalid }

    // MARK: - Persistence

    private func load() {
        activeId = defaults.string(forKey: activeIdKey)
        guard let data = defaults.data(forKey: profilesKey) else {
            profiles = []
            return
        }
        do {
            var decoded = try JSONDecoder().decode([VpnProfile].self, from: data)
            for i in decoded.indices {
                let id = decoded[i].id
                decoded[i].certPem = Keychain.get(certKey(id))
                decoded[i].keyPem = Keychain.get(keyKey(id))
            }
            profiles = decoded
        } catch {
            log.error("Failed to decode profiles.json: \(error.localizedDescription, privacy: .public)")
            profiles = []
        }
    }

    private func save() {
        // Persist secrets to Keychain; swallow individual failures so one
        // broken entry doesn't corrupt the whole batch.
        for profile in profiles {
            if let pem = profile.certPem {
                do { try Keychain.set(pem, forKey: certKey(profile.id)) }
                catch { log.error("Keychain.set cert failed: \(String(describing: error), privacy: .public)") }
            }
            if let key = profile.keyPem {
                do { try Keychain.set(key, forKey: keyKey(profile.id)) }
                catch { log.error("Keychain.set key failed: \(String(describing: error), privacy: .public)") }
            }
        }

        let sanitized = profiles.map { $0.sanitizedForUserDefaults }
        do {
            let data = try JSONEncoder().encode(sanitized)
            defaults.set(data, forKey: profilesKey)
        } catch {
            log.error("Failed to encode profiles.json: \(error.localizedDescription, privacy: .public)")
        }

        if let activeId {
            defaults.set(activeId, forKey: activeIdKey)
        } else {
            defaults.removeObject(forKey: activeIdKey)
        }
    }

    private func deleteKeychainSecrets(profileId: String) {
        do { try Keychain.delete(certKey(profileId)) } catch {
            log.error("Keychain.delete cert failed: \(String(describing: error), privacy: .public)")
        }
        do { try Keychain.delete(keyKey(profileId)) } catch {
            log.error("Keychain.delete key failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func certKey(_ id: String) -> String { "profile.\(id).cert" }
    private func keyKey(_ id: String) -> String { "profile.\(id).key" }
}
