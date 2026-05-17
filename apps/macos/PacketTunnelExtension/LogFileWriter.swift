//
//  LogFileWriter.swift
//  GhostStream PacketTunnelExtension (macOS)
//
//  ADR 0008 — verbose debug observability.
//
//  Persists every `LogFrame` the Provider receives to a per-day NDJSON
//  file under ~/Library/Logs/GhostStream/. The file is the canonical
//  artefact for shipping logs to an LLM agent — `tail -n 1000` produces
//  a structured stream the model can parse directly.
//
//  Threading: a single serial DispatchQueue. `append(_:)` is non-blocking
//  (queue.async). The file handle is cached and reused; rotation only
//  happens on day change or when the active file exceeds 100 MB.
//
//  Rotation:
//    - On each first append of a calendar day the previous current file
//      is renamed `runtime.log.YYYY-MM-DD` (date of its last mtime).
//    - On size > 100 MB the file is rolled over to
//      `runtime.log.YYYY-MM-DD.N` (N starts at 1, increments).
//    - On `init` (and once per day on first append), files older than
//      7 days are removed.
//

import Foundation
import os.log
import PhantomKit

public final class LogFileWriter {

    public static let shared = LogFileWriter()

    private let queue = DispatchQueue(label: "com.ghoststream.client.logwriter", qos: .utility)
    private let fileManager = FileManager.default
    private let osLog = Logger(subsystem: "com.ghoststream.client.tunnel", category: "logwriter")
    private let maxFileBytes: UInt64 = 100 * 1024 * 1024
    private let retentionDays = 7

    private var directoryURL: URL
    private var currentURL: URL
    private var handle: FileHandle?
    private var currentDayKey: String
    private var bytesWritten: UInt64 = 0
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()
    private let dayFormatter: DateFormatter = {
        // Audit PROV-H9 — log archives are named by *local* day so the
        // file the user sees matches when they used the app. UTC was a
        // surprise for users on UTC+offset timezones (especially around
        // midnight in Europe/Moscow), where the running day didn't match
        // the rotated-archive filename.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    public init() {
        let dir = LogFileWriter.defaultDirectory()
        self.directoryURL = dir
        self.currentURL = dir.appendingPathComponent("runtime.log")
        self.currentDayKey = dayFormatter.string(from: Date())
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        sweepOldFiles()
    }

    /// All path resolution lives in `PhantomKit.LogPathResolver` — this
    /// class only owns the writer pipeline (queue, rotation, encoding).
    /// Both the extension (here) and the host UI (SettingsView /
    /// TailView reveal buttons) share the same resolver so the buttons
    /// always point at the file the writer is actually writing to.
    public static func defaultDirectory() -> URL {
        LogPathResolver.defaultDirectory()
    }

    public static func defaultRuntimeLogURL() -> URL {
        LogPathResolver.defaultRuntimeLogURL()
    }

    /// Append a single frame as one NDJSON line. Non-blocking — work is
    /// dispatched onto the writer queue; a slow disk never blocks the
    /// caller's runtime callback path.
    public func append(_ frame: LogFrameLike) {
        let payload = LogFilePayload(
            tsUnixMs: frame.tsUnixMs,
            tsUnixUs: frame.tsUnixUs,
            level: frame.level,
            msg: frame.msg,
            category: frame.category,
            fields: frame.fields
        )
        queue.async { [weak self] in
            self?.write(payload)
        }
    }

    /// Force-flush the underlying file handle. Used on `stopTunnel` to
    /// ensure the last few frames hit disk before the extension exits.
    ///
    /// Implementation note: `queue.sync` blocks the caller until **all**
    /// pending writes drain. In TRACE mode the writer can have thousands
    /// of pending NDJSON lines queued; a blocking flush there pushed
    /// `stopTunnel` past the NE extension takedown deadline (~5 s) and
    /// the system killed the extension mid-flush. We now dispatch the
    /// synchronize asynchronously and wait with a bounded `DispatchSemaphore`
    /// so worst case we lose the tail of the queue instead of the whole
    /// shutdown sequence.
    public func flush(timeout: DispatchTime = .now() + 1.0) {
        let sem = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            if let handle = self?.handle {
                try? handle.synchronize()
            }
            sem.signal()
        }
        _ = sem.wait(timeout: timeout)
    }

    // MARK: - Internal

    private func write(_ payload: LogFilePayload) {
        do {
            try ensureRotation()
            let line = try encoder.encode(payload)
            guard let handle = handle else { return }
            handle.write(line)
            handle.write(Data([0x0a]))
            bytesWritten &+= UInt64(line.count + 1)
        } catch {
            osLog.error("logwriter append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureRotation() throws {
        let today = dayFormatter.string(from: Date())
        if today != currentDayKey {
            try rotateForDay(previousKey: currentDayKey)
            currentDayKey = today
            sweepOldFiles()
        }

        if handle == nil {
            try openHandle()
        }

        if bytesWritten >= maxFileBytes {
            try rotateForSize()
        }
    }

    private func openHandle() throws {
        if !fileManager.fileExists(atPath: currentURL.path) {
            // Touch a fresh file. atomic write so any interrupted state is
            // not left behind.
            try Data().write(to: currentURL, options: .atomic)
            // PRIVACY: runtime.log contains the structured event stream
            // including SNI / server IP / tun_addr / handshake fields.
            // Default user-home permissions (0644) would let any other
            // local user read it. Lock it to 0600 right after create.
            try lockdownPermissions(currentURL)
        } else {
            // Existing file may pre-date the privacy fix — re-apply 0600.
            try? lockdownPermissions(currentURL)
        }
        handle = try FileHandle(forWritingTo: currentURL)
        try handle?.seekToEnd()
        let size = (try? fileManager.attributesOfItem(atPath: currentURL.path)[.size] as? UInt64) ?? 0
        bytesWritten = size

        // First-time mtime check: if the existing file is from a previous
        // day we still want to roll it over to runtime.log.YYYY-MM-DD
        // before appending today's frames.
        if let mtime = try? fileManager.attributesOfItem(atPath: currentURL.path)[.modificationDate] as? Date {
            let mtimeKey = dayFormatter.string(from: mtime)
            if mtimeKey != currentDayKey {
                try handle?.close()
                handle = nil
                try rotateForDay(previousKey: mtimeKey)
                try Data().write(to: currentURL, options: .atomic)
                try lockdownPermissions(currentURL)
                handle = try FileHandle(forWritingTo: currentURL)
                try handle?.seekToEnd()
                bytesWritten = 0
            }
        }
    }

    private func rotateForDay(previousKey: String) throws {
        try handle?.close()
        handle = nil
        bytesWritten = 0

        guard fileManager.fileExists(atPath: currentURL.path) else { return }
        let archive = directoryURL.appendingPathComponent("runtime.log.\(previousKey)")
        try? fileManager.removeItem(at: archive)
        try fileManager.moveItem(at: currentURL, to: archive)
    }

    private func rotateForSize() throws {
        try handle?.close()
        handle = nil

        var n = 1
        var archive = directoryURL.appendingPathComponent("runtime.log.\(currentDayKey).\(n)")
        while fileManager.fileExists(atPath: archive.path) {
            n += 1
            archive = directoryURL.appendingPathComponent("runtime.log.\(currentDayKey).\(n)")
        }
        try fileManager.moveItem(at: currentURL, to: archive)
        bytesWritten = 0
        try Data().write(to: currentURL, options: .atomic)
        // PRIVACY: see `openHandle()` — keep the new active file at 0600
        // so a rotated batch never becomes world-readable for a window.
        try lockdownPermissions(currentURL)
        handle = try FileHandle(forWritingTo: currentURL)
        try handle?.seekToEnd()
    }

    /// Restrict a freshly-created log file to owner read/write only.
    /// Required for /Users/<user>/Library/Logs/GhostStream/runtime.log
    /// — the directory inherits 0755 from HOME and would otherwise leave
    /// the structured log readable by any other local account.
    private func lockdownPermissions(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    private func sweepOldFiles() {
        let cutoff = Date().addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for url in entries {
            // Never sweep the active file; only rotated archives.
            guard url.lastPathComponent != "runtime.log" else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            if mtime < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }
}

/// Decoupling protocol so `LogFileWriter` does not import the `LogFrame`
/// model directly — this keeps the writer testable in isolation and
/// avoids a hard dependency on `PhantomKit` from this extension-only
/// file (the Provider passes a frame via the conformance defined below).
public protocol LogFrameLike {
    var tsUnixMs: UInt64 { get }
    var tsUnixUs: UInt64 { get }
    var level: String { get }
    var msg: String { get }
    var category: String? { get }
    var fields: [String: String]? { get }
}

private struct LogFilePayload: Encodable {
    let tsUnixMs: UInt64
    let tsUnixUs: UInt64
    let level: String
    let msg: String
    let category: String?
    let fields: [String: String]?

    enum CodingKeys: String, CodingKey {
        case tsUnixMs = "ts_unix_ms"
        case tsUnixUs = "ts_unix_us"
        case level
        case msg
        case category
        case fields
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tsUnixMs, forKey: .tsUnixMs)
        if tsUnixUs != 0 {
            try c.encode(tsUnixUs, forKey: .tsUnixUs)
        }
        try c.encode(level, forKey: .level)
        try c.encode(msg, forKey: .msg)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encodeIfPresent(fields, forKey: .fields)
    }
}
