import Foundation

/// Single source of truth for the runtime.log path on Apple platforms.
///
/// The PacketTunnelExtension runs as `root` on macOS, so its
/// `.libraryDirectory` resolves to `/var/root/Library/Logs/...` —
/// invisible to the user. We anchor the log file in the App Group
/// container instead, which resolves to the user-home
/// `~/Library/Group Containers/group.com.ghoststream.client/Logs/` from
/// both the host (running as the user) and the system extension
/// (running as root).
///
/// The host UI (`SettingsView` reveal-in-Finder, `TailView`
/// reveal-in-Finder) and the extension's `LogFileWriter` MUST resolve
/// through this single helper — otherwise the buttons point at one
/// directory while the writer writes to another (the symptom that
/// triggered ADR 0008 architect review #CRITICAL 1).
public enum LogPathResolver {

    /// Shared App Group identifier — must match `group.*` listed in
    /// both the host and the extension entitlements.
    public static let appGroupIdentifier = "group.com.ghoststream.client"

    /// Default log directory.
    ///
    /// Resolution order (per ADR 0008 §4 + sandbox/root realities):
    ///   1. App Group container `Logs/` — primary. Resolves to
    ///      `~/Library/Group Containers/group.com.ghoststream.client/Logs/`
    ///      from both host and extension.
    ///   2. User-domain `~/Library/Logs/GhostStream/` — fallback for the
    ///      host app when the App Group is somehow unreachable. Lands
    ///      in `/var/root/Library/Logs/` from the extension and will be
    ///      invisible to the user — kept only as last resort.
    ///   3. `$TMPDIR/GhostStream/` — final fallback so the writer never
    ///      crashes on an unwritable system.
    public static func defaultDirectory() -> URL {
        let fm = FileManager.default
        if let group = fm.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            let dir = group.appendingPathComponent("Logs", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if let logs = try? fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Logs/GhostStream", isDirectory: true) {
            try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
            return logs
        }
        return fm.temporaryDirectory
            .appendingPathComponent("GhostStream", isDirectory: true)
    }

    /// Canonical path to the active runtime.log file.
    public static func defaultRuntimeLogURL() -> URL {
        defaultDirectory().appendingPathComponent("runtime.log")
    }

    /// Human-readable path for use in UI labels. Replaces the user's
    /// home with `~` so the SettingsView description stays compact.
    public static var displayPath: String {
        let raw = defaultRuntimeLogURL().path
        let home = NSString(string: "~/").expandingTildeInPath
        if raw.hasPrefix(home) {
            return "~/" + String(raw.dropFirst(home.count))
        }
        return raw
    }
}
