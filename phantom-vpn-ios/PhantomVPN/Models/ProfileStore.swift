import Foundation
import Combine

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [VpnProfile] = []
    @Published var activeProfileId: String?

    var activeProfile: VpnProfile? {
        profiles.first(where: { $0.id == activeProfileId }) ?? profiles.first
    }

    private let storeURL: URL = {
        let dir = AppPaths.sharedContainerURL().appendingPathComponent("profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }()

    private init() {
        load()
    }

    func addProfile(_ profile: VpnProfile) {
        profiles.append(profile)
        if activeProfileId == nil {
            activeProfileId = profile.id
        }
        save()
    }

    func updateProfile(_ profile: VpnProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        save()
    }

    func deleteProfile(id: String) {
        guard let target = profiles.first(where: { $0.id == id }) else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
        }
        cleanupFiles(for: target)
        save()
    }

    func setActive(id: String) {
        activeProfileId = id
        save()
    }

    func importConnString(name: String, connString: String) throws {
        let parsed = try ConnStringParser.parse(connString)
        let certDir = AppPaths.certsDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: certDir, withIntermediateDirectories: true)

        let cert = certDir.appendingPathComponent("client.crt")
        let key = certDir.appendingPathComponent("client.key")
        let ca = certDir.appendingPathComponent("ca.crt")
        try parsed.cert.write(to: cert, atomically: true, encoding: .utf8)
        try parsed.key.write(to: key, atomically: true, encoding: .utf8)
        if let caValue = parsed.ca {
            try caValue.write(to: ca, atomically: true, encoding: .utf8)
        }

        let profile = VpnProfile(
            name: name.isEmpty ? "Подключение" : name,
            serverAddr: parsed.addr,
            serverName: parsed.sni,
            insecure: parsed.ca == nil,
            certPath: cert.path,
            keyPath: key.path,
            caCertPath: parsed.ca == nil ? nil : ca.path,
            tunAddr: parsed.tun,
            adminUrl: parsed.adminUrl,
            adminToken: parsed.adminToken
        )
        addProfile(profile)
    }

    private func cleanupFiles(for profile: VpnProfile) {
        [profile.certPath, profile.keyPath, profile.caCertPath ?? ""]
            .filter { !$0.isEmpty }
            .forEach { try? FileManager.default.removeItem(atPath: $0) }
        let dir = URL(fileURLWithPath: profile.certPath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
    }

    private struct StoreData: Codable {
        var profiles: [VpnProfile]
        var activeId: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let parsed = try? JSONDecoder().decode(StoreData.self, from: data) else {
            return
        }
        profiles = parsed.profiles
        activeProfileId = parsed.activeId
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(StoreData(profiles: profiles, activeId: activeProfileId)) else {
            return
        }
        try? data.write(to: storeURL, options: .atomic)
    }
}
