import Foundation

enum AppPaths {
    static let appGroupId = "group.com.ghoststream.vpn"

    static func sharedContainerURL() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return fallback.appendingPathComponent("GhostStreamFallback", isDirectory: true)
    }

    static func certsDirectory() -> URL {
        let dir = sharedContainerURL().appendingPathComponent("certificates", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
