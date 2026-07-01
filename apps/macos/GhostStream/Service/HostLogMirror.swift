//
//  HostLogMirror.swift
//  GhostStream (macOS)
//
//  Host-side NDJSON-зеркало live-лога туннеля.
//
//  Почему оно существует: system extension работает под root и в sandbox —
//  его `LogFileWriter` пишет runtime.log в group-контейнер root'а
//  (/var/root/Library/Group Containers/…), который пользователь не видит,
//  а sandbox не пускает root-процесс в пользовательский контейнер. Кнопки
//  «Reveal runtime.log» в TailView/SettingsView резолвятся через
//  `LogPathResolver` в ПОЛЬЗОВАТЕЛЬСКИЙ контейнер — до этого зеркала там
//  никогда ничего не было («runtime.log not yet created», июль 2026).
//
//  Хост получает полный поток LogFrame через IPC subscribeLogs
//  (TunnelLogStore) и дублирует его сюда. Формат строк совместим с
//  extension-side LogFileWriter (NDJSON, те же ключи wire-формата).
//

import Foundation
import PhantomKit

public final class HostLogMirror {

    public static let shared = HostLogMirror()

    private let queue = DispatchQueue(label: "com.ghoststream.client.hostlogmirror", qos: .utility)
    private let fileManager = FileManager.default
    private let maxFileBytes: UInt64 = 50 * 1024 * 1024
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private var fileURL: URL { LogPathResolver.defaultRuntimeLogURL() }

    private init() {}

    /// Неблокирующая запись пачки фреймов (вызывается с main actor после
    /// каждого IPC-полла — вся работа уходит на serial-очередь).
    public func append(_ frames: [LogFrame]) {
        guard !frames.isEmpty else { return }
        queue.async { [weak self] in
            self?.write(frames)
        }
    }

    private func write(_ frames: [LogFrame]) {
        do {
            try ensureHandle()
            guard let handle else { return }
            for frame in frames {
                let line = try encoder.encode(frame)
                handle.write(line)
                handle.write(Data([0x0A]))
                bytesWritten &+= UInt64(line.count + 1)
            }
            if bytesWritten >= maxFileBytes {
                try rotate()
            }
        } catch {
            // Диск/права — не повод ронять UI; зеркало best-effort.
            handle = nil
        }
    }

    private func ensureHandle() throws {
        guard handle == nil else { return }
        let url = fileURL
        if !fileManager.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
            // PRIVACY: лог содержит SNI/server IP/tun_addr — только владелец.
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path
            )
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        bytesWritten = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        bytesWritten = 0
        let archive = fileURL.deletingLastPathComponent()
            .appendingPathComponent("runtime.log.1")
        try? fileManager.removeItem(at: archive)
        try fileManager.moveItem(at: fileURL, to: archive)
    }
}
