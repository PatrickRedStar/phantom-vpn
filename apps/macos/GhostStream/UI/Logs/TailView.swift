//
//  TailView.swift
//  GhostStream (macOS)
//
//  «Логи» (mockup.html, pane logs): нативная Table — время, уровень,
//  сообщение; новые сверху. Уровень — сегменты над таблицей, поиск —
//  ToolbarSearchField в тулбаре. Копирование — меню строки и ⌘C по выделению; клик
//  буфер не трогает. Одна кнопка «Экспорт» (⌘E). Тот же вид — в
//  отдельном окне логов (⇧⌘L).
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI
import UniformTypeIdentifiers

public struct TailView: View {

    @Environment(\.gsColors) private var C
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TunnelLogStore.self) private var logStore

    @State private var level: LevelFilter = .all
    @State private var search = ""
    @State private var rows: [LogRow] = []
    @State private var selection = Set<LogRow.ID>()
    @State private var filterTask: Task<Void, Never>?
    @State private var notice: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: GsSpace.s) {
            levelPicker
            table
            footer
        }
        .padding(.horizontal, GsSpace.xxl)
        .padding(.top, GsSpace.s)
        .padding(.bottom, GsSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ToolbarSearchField(text: $search, prompt: L("srv.search"))
            }
            ConsoleToolbarItems()
        }
        .onAppear { recompute(debounce: false) }
        // `revision`, а не `logs.count`: после насыщения буфера count
        // стоит на месте (LOG-1).
        .onChange(of: logStore.revision) { recompute(debounce: false) }
        .onChange(of: level) { recompute(debounce: false) }
        .onChange(of: search) { recompute(debounce: true) }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            notice = nil
        }
        .onDisappear { filterTask?.cancel() }
        .task { logStore.start(stateManager: stateMgr) }
    }

    /// Уровень — маленькие сегменты над таблицей (в тулбаре были огромные и серые).
    private var levelPicker: some View {
        Picker(L("log.filter"), selection: $level) {
            Text(L("log.filter.all")).tag(LevelFilter.all)
            Text(L("log.filter.warn")).tag(LevelFilter.warn)
            Text(L("log.filter.error")).tag(LevelFilter.error)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .tint(C.signal)
    }

    // MARK: - Table

    private var table: some View {
        Table(rows, selection: $selection) {
            TableColumn(L("log.col.time")) { row in
                Text(row.time)
                    .font(GsType.mono.font)
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 72, max: 90)

            TableColumn(L("log.col.level")) { row in
                Text(row.levelTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(levelColor(row.level))
            }
            .width(min: 64, ideal: 80, max: 100)

            TableColumn(L("log.col.message")) { row in
                Text(row.message)
                    .font(GsType.mono.font)
                    .lineLimit(1)
                    .help(row.message)
            }
        }
        .gsType(.body)
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(C.bgElev, in: RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous).stroke(C.hair, lineWidth: 1))
        .contextMenu(forSelectionType: LogRow.ID.self) { ids in
            if !ids.isEmpty {
                Button(L("log.copy")) { copy(ids) }
            }
        }
        .onCopyCommand {
            [NSItemProvider(object: text(for: selection) as NSString)]
        }
        .overlay {
            if rows.isEmpty {
                Text(emptyText)
                    .gsType(.body)
                    .foregroundStyle(C.textDim)
            }
        }
    }

    private var emptyText: String {
        if logStore.lastErrorMessage != nil { return L("log.unavailable") }
        if logStore.logs.isEmpty && stateMgr.statusFrame.state == .disconnected { return L("log.empty.off") }
        return L("log.empty")
    }

    private var footer: some View {
        HStack(spacing: GsSpace.m) {
            Text(notice ?? L("log.hint"))
                .gsType(.caption)
                .foregroundStyle(C.textDim)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(action: export) {
                Label(L("log.export"), systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: .command)
            .gsGlassButton()
            .disabled(logStore.logs.isEmpty)
        }
        .padding(.leading, GsSpace.s)
    }

    private func levelColor(_ level: LogFrameFilter.Level) -> Color {
        switch level {
        case .error:      return C.danger
        case .warn:       return C.warn
        case .debug:      return C.textFaint
        case .info, .ok:  return C.textDim
        }
    }

    // MARK: - Filtering

    /// Фильтр по буферу (до 10k строк) — вне main actor; устаревший
    /// пересчёт отменяется, поиск — с паузой 300 мс.
    private func recompute(debounce: Bool) {
        filterTask?.cancel()
        let frames = logStore.logs
        let level = level
        let search = search.trimmingCharacters(in: .whitespaces)
        let titles = LogRow.Titles()
        filterTask = Task.detached(priority: .userInitiated) {
            if debounce { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let result = frames.reversed().compactMap { frame -> LogRow? in
                let normalized = LogFrameFilter.normalizedLevel(frame.level)
                guard level.allows(normalized),
                      LogFrameFilter.matches(level: frame.level, msg: frame.msg, category: frame.category,
                                             fields: frame.fields, search: search, regex: nil, useRegex: false)
                else { return nil }
                return LogRow(frame: frame, level: normalized, titles: titles)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { rows = result }
        }
    }

    // MARK: - Copy / export

    /// Выделенные строки по порядку времени.
    private func text(for ids: Set<LogRow.ID>) -> String {
        rows.filter { ids.contains($0.id) }.reversed().map(\.line).joined(separator: "\n")
    }

    private func copy(_ ids: Set<LogRow.ID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text(for: ids), forType: .string)
    }

    /// Весь буфер в текстовый файл, с версией приложения и macOS сверху.
    private func export() {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        panel.nameFieldStringValue = "GhostStream-logs-\(stamp).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let info = Bundle.main.infoDictionary
        let header = "GhostStream \(info?["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info?["CFBundleVersion"] as? String ?? "?")) · macOS "
            + ProcessInfo.processInfo.operatingSystemVersionString
        let titles = LogRow.Titles()
        let body = logStore.logs.map {
            LogRow(frame: $0, level: LogFrameFilter.normalizedLevel($0.level), titles: titles).line
        }
        do {
            try ([header, ""] + body).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            notice = String(format: L("log.exported"), url.lastPathComponent)
        } catch {
            notice = String(format: L("log.export.failed"), error.localizedDescription)
        }
    }
}

// MARK: - Model

enum LevelFilter: Hashable {
    case all, warn, error

    func allows(_ level: LogFrameFilter.Level) -> Bool {
        switch self {
        case .all:   return true
        case .warn:  return level == .warn || level == .error
        case .error: return level == .error
        }
    }
}

private struct LogRow: Identifiable, Sendable {
    let id: String
    let time: String
    let level: LogFrameFilter.Level
    let levelTitle: String
    let message: String

    /// Подписи уровней, снятые на main actor (L()) для фонового фильтра.
    struct Titles: Sendable {
        let info, warn, error, debug: String

        @MainActor init() {
            info = L("log.lv.info")
            warn = L("log.lv.warn")
            error = L("log.lv.error")
            debug = L("log.lv.debug")
        }

        func title(_ level: LogFrameFilter.Level) -> String {
            switch level {
            case .error:      return error
            case .warn:       return warn
            case .debug:      return debug
            case .info, .ok:  return info
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init(frame: LogFrame, level: LogFrameFilter.Level, titles: Titles) {
        id = frame.id
        time = Self.timeFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(frame.timestampUs) / 1_000_000))
        self.level = level
        levelTitle = titles.title(level)
        if let fields = frame.fields, !fields.isEmpty {
            message = frame.msg + " · " + fields.keys.sorted().map { "\($0)=\(fields[$0] ?? "")" }.joined(separator: " ")
        } else {
            message = frame.msg
        }
    }

    var line: String { "\(time)  \(levelTitle)  \(message)" }
}
