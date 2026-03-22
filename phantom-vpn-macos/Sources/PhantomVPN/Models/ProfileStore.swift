import Foundation
import Combine

class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [VpnProfile] = []
    @Published var activeProfileId: String?

    var activeProfile: VpnProfile? {
        profiles.first { $0.id == activeProfileId } ?? profiles.first
    }

    private let storeURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhantomVPN", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }()

    private init() { load() }

    func addProfile(_ profile: VpnProfile) {
        profiles.append(profile)
        if activeProfileId == nil { activeProfileId = profile.id }
        save()
    }

    func deleteProfile(id: String) {
        profiles.removeAll { $0.id == id }
        if activeProfileId == id { activeProfileId = profiles.first?.id }
        save()
    }

    func setActive(id: String) {
        activeProfileId = id
        save()
    }

    private struct StoreData: Codable {
        var profiles: [VpnProfile]
        var activeId: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let d = try? JSONDecoder().decode(StoreData.self, from: data) else { return }
        profiles = d.profiles
        activeProfileId = d.activeId
    }

    private func save() {
        if let data = try? JSONEncoder().encode(StoreData(profiles: profiles, activeId: activeProfileId)) {
            try? data.write(to: storeURL)
        }
    }
}
