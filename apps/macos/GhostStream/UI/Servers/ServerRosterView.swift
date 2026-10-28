//
//  ServerRosterView.swift
//  GhostStream (macOS)
//
//  «Серверы» (mockup.html, pane servers): нативная Table профилей —
//  профиль + хост, маршрут, задержка, срок доступа, состояние. Активный
//  профиль отмечен одним маркером — точкой состояния туннеля.
//  Двойной щелчок — подключиться, ⌘N — добавить, ⌫ — удалить.
//

import AppKit
import Network
import PhantomKit
import PhantomUI
import SwiftUI

public struct ServerRosterView: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow
    @Environment(ProfilesStore.self) private var profiles
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(DockPolicyController.self) private var dock

    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\RosterRow.name)]
    @State private var search = ""
    @State private var rtt: [String: UInt32] = [:]
    @State private var probed = false
    @State private var sheet: EditorSheet?
    @State private var deleting: VpnProfile?
    @State private var notice: Notice?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: GsSpace.s) {
            if profiles.profiles.isEmpty {
                emptyState
            } else {
                table
                footer
            }
        }
        .padding(.horizontal, GsSpace.xxl)
        .padding(.top, GsSpace.s)
        .padding(.bottom, GsSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .searchable(text: $search, placement: .toolbar, prompt: L("srv.search"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .new } label: {
                    Label(L("srv.add"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help(L("srv.add"))
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .new:            ProfileEditorSheet()
            case .edit(let id):   ProfileEditorSheet(editProfileId: id)
            }
        }
        .alert(
            deleting.map { String(format: L("profile.delete.confirm"), $0.name) } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { profile in
            Button(L("profile.delete"), role: .destructive) { profiles.remove(id: profile.id) }
            Button(L("general.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("srv.delete.message"))
        }
        .task(id: profiles.profiles.map(\.effectiveServerAddr)) { await probeLoop() }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            notice = nil
        }
        .onAppear { if selection == nil { selection = profiles.activeProfile?.id } }
    }

    // MARK: - Table

    private var table: some View {
        let rows = rows
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("srv.col.profile"), value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                        .lineLimit(1)
                    Text(row.host)
                        .font(.custom(GsFontName.jetBrainsMono, size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, GsSpace.xs)
            }
            .width(min: 180, ideal: 250)

            TableColumn(L("srv.col.route"), value: \.route) { row in
                Text(row.route)
            }
            .width(min: 90, ideal: 120)

            TableColumn(L("srv.col.latency"), value: \.rttSort) { row in
                if let ms = row.rtt {
                    Text(String(format: L("srv.ms"), Int32(ms))).monospacedDigit()
                } else {
                    Text(probed ? L("srv.no_reply") : "—").foregroundStyle(.secondary)
                }
            }
            .width(min: 70, ideal: 90)

            TableColumn(L("srv.col.access"), value: \.accessSort) { row in
                Text(row.access.text)
                    .monospacedDigit()
                    .foregroundStyle(row.access.dim ? .secondary : .primary)
            }
            .width(min: 80, ideal: 100)

            TableColumn(L("srv.col.state"), value: \.stateSort) { row in
                stateLabel(row)
            }
            .width(min: 110, ideal: 140)
        }
        .gsType(.body)
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(C.bgElev, in: RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous).stroke(C.hair, lineWidth: 1))
        // По высоте строк, как в макете: иначе inset-таблица рисует до низа
        // пустые полосы-заполнители. Больше строк — прокрутка.
        .frame(maxHeight: GsTable.height(rows: rows.count, rowHeight: GsTable.twoLineRow))
        .contextMenu(forSelectionType: String.self) { ids in
            if let profile = ids.first.flatMap(profiles.load(id:)) {
                rowMenu(profile)
            }
        } primaryAction: { ids in
            if let profile = ids.first.flatMap(profiles.load(id:)) { connect(profile) }
        }
        .onDeleteCommand {
            deleting = selection.flatMap(profiles.load(id:))
        }
    }

    @ViewBuilder
    private func rowMenu(_ profile: VpnProfile) -> some View {
        let active = profiles.activeProfile?.id == profile.id
        if !(active && VpnTunnelController.isUp(stateMgr.statusFrame.state)) {
            Button(L("srv.connect")) { connect(profile) }
        }
        if !active {
            Button(L("srv.make_active")) { profiles.setActive(id: profile.id) }
        }
        Button(L("srv.edit")) { sheet = .edit(profile.id) }
        Divider()
        Button(L("srv.delete"), role: .destructive) { deleting = profile }
    }

    @ViewBuilder
    private func stateLabel(_ row: RosterRow) -> some View {
        if row.active {
            let state = stateMgr.statusFrame.state
            HStack(spacing: 7) {
                StateDot(state: state)
                Text(state.title)
            }
        } else if row.noAccess {
            HStack(spacing: 7) {
                Circle().fill(C.danger).frame(width: 8, height: 8)
                Text(L("srv.state.no_access"))
            }
        } else {
            Text(L("srv.state.ready")).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        Text(notice?.text ?? L("srv.hint"))
            .gsType(.caption)
            .foregroundStyle(notice?.isError == true ? C.danger : C.textDim)
            .padding(.horizontal, GsSpace.s)
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: GsSpace.m) {
            Text(L("srv.empty.title"))
                .gsType(.title)
                .foregroundStyle(C.bone)
            Text(L("srv.empty.text"))
                .gsType(.body)
                .foregroundStyle(C.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(action: pasteFromClipboard) {
                Label(L("srv.paste"), systemImage: "link")
                    .gsType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(C.bg)
                    .padding(.horizontal, GsSpace.xs)
            }
            .controlSize(.large)
            .gsProminentButton(tint: C.signal)
            .padding(.top, GsSpace.s)
            if let notice {
                Text(notice.text)
                    .gsType(.caption)
                    .foregroundStyle(notice.isError ? C.danger : C.textDim)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    private var rows: [RosterRow] {
        let activeId = profiles.activeProfile?.id
        let query = search.trimmingCharacters(in: .whitespaces)
        return profiles.profiles
            .filter {
                query.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(query)
                    || $0.serverName.localizedCaseInsensitiveContains(query)
            }
            .map { RosterRow(profile: $0, active: $0.id == activeId, rtt: rtt[$0.id]) }
            .sorted(using: sortOrder)
    }

    // MARK: - Actions

    /// Сделать активным и поднять туннель. Поднятый туннель на другом
    /// профиле переключает `VpnTunnelController.activeProfileChanged`.
    private func connect(_ profile: VpnProfile) {
        profiles.setActive(id: profile.id)
        guard !VpnTunnelController.isUp(stateMgr.statusFrame.state) else { return }
        Task {
            await ConnectAction.toggle {
                openWindow(id: "welcome")
                dock.activateForegroundWindow()
            }
        }
    }

    private func pasteFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        switch profiles.importLink(text) {
        case .added(let profile):
            selection = profile.id
            notice = Notice(text: String(format: L("srv.notice.added"), profile.name))
        case .duplicate(let profile):
            selection = profile.id
            notice = Notice(text: String(format: L("srv.notice.duplicate"), profile.name))
        case .notALink:
            notice = Notice(text: L("srv.notice.no_link"), isError: true)
        case .invalid:
            notice = Notice(text: L("srv.notice.invalid"), isError: true)
        }
    }

    // MARK: - RTT probe

    private func probeLoop() async {
        #if DEBUG
        if DebugDemo.isActive {
            rtt = ["demo-relay": 38, "demo-direct": 61]
            probed = true
            return
        }
        #endif
        while !Task.isCancelled {
            let targets = profiles.profiles.map { ($0.id, $0.effectiveServerAddr) }
            var next: [String: UInt32] = [:]
            await withTaskGroup(of: (String, UInt32?).self) { group in
                for (id, addr) in targets {
                    group.addTask { (id, await Self.measureRTT(to: addr)) }
                }
                for await (id, ms) in group {
                    if let ms { next[id] = ms }
                }
            }
            guard !Task.isCancelled else { return }
            rtt = next
            probed = true
            try? await Task.sleep(for: .seconds(30))
        }
    }

    /// Время TCP-рукопожатия до точки входа (с реле — до реле), 3 с таймаут.
    private nonisolated static func measureRTT(to serverAddr: String) async -> UInt32? {
        guard let endpoint = endpoint(from: serverAddr) else { return nil }
        let connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: endpoint.port, using: .tcp)
        let startedAt = Date()
        return await withCheckedContinuation { continuation in
            let gate = RTTProbeCompletionGate(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(UInt32(max(1, min(9_999, Date().timeIntervalSince(startedAt) * 1_000))))
                case .failed, .waiting:
                    gate.resume(nil)
                case .cancelled, .setup, .preparing:
                    break
                @unknown default:
                    gate.resume(nil)
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { gate.resume(nil) }
        }
    }

    private nonisolated static func endpoint(from serverAddr: String) -> (host: String, port: NWEndpoint.Port)? {
        let trimmed = serverAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed.contains("://") ? trimmed : "tcp://\(trimmed)"),
              let host = components.host, !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: components.port ?? 443))
        else { return nil }
        return (host, port)
    }
}

// MARK: - Models

/// Высота inset-таблицы под содержимое (шапка + отступы + строки).
enum GsTable {
    static let twoLineRow: CGFloat = 47
    static let oneLineRow: CGFloat = 24.1

    static func height(rows: Int, rowHeight: CGFloat) -> CGFloat {
        38 + CGFloat(max(rows, 1)) * rowHeight
    }
}

private enum EditorSheet: Identifiable {
    case new
    case edit(String)

    var id: String {
        switch self {
        case .new:            return "new"
        case .edit(let id):   return id
        }
    }
}

private struct Notice: Equatable {
    let text: String
    var isError = false
}

private struct RosterRow: Identifiable {
    let id: String
    let name: String
    let host: String
    let route: String
    let rtt: UInt32?
    let access: (text: String, dim: Bool)
    let accessSort: Int64
    let active: Bool
    let noAccess: Bool

    @MainActor
    init(profile: VpnProfile, active: Bool, rtt: UInt32?) {
        id = profile.id
        name = profile.name
        host = profile.serverName.isEmpty ? profile.serverAddr : profile.serverName
        route = L(profile.relayActive ? "srv.route.relay" : "srv.route.direct")
        self.rtt = rtt
        self.active = active
        accessSort = profile.cachedExpiresAt ?? .max

        let expires = profile.cachedExpiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let expired = expires.map { $0 < .now } ?? false
        noAccess = profile.cachedEnabled == false || expired
        if let expires, expired {
            access = (String(format: L("srv.access.expired"),
                             expires.formatted(.dateTime.day(.twoDigits).month(.twoDigits))), true)
        } else if let expires {
            access = (expires.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()), false)
        } else if profile.cachedEnabled == true {
            access = (L("srv.access.forever"), true)
        } else {
            access = ("—", true)
        }
    }

    var rttSort: UInt32 { rtt ?? .max }
    /// Активный — первым, затем готовые, затем без доступа.
    var stateSort: Int { active ? 0 : noAccess ? 2 : 1 }
}

// MARK: - Import without duplicates

/// Итог импорта ghs://-ссылки.
enum LinkImportResult {
    case added(VpnProfile)
    case duplicate(VpnProfile)
    case notALink
    case invalid
}

extension ProfilesStore {
    /// Импорт без дублей: та же ссылка или тот же клиентский сертификат на
    /// том же сервере — «Профиль уже есть» вместо второй копии.
    func importLink(_ raw: String) -> LinkImportResult {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard link.hasPrefix("ghs://") else { return .notALink }
        guard let parsed = PhantomBridge.parseConnString(link) else { return .invalid }
        let cert = parsed.certPem.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = profiles.first(where: {
            $0.connString == link
                || ($0.serverAddr == parsed.serverAddr
                    && $0.certPem?.trimmingCharacters(in: .whitespacesAndNewlines) == cert)
        }) {
            return .duplicate(existing)
        }
        guard let profile = try? importFromConnString(link) else { return .invalid }
        return .added(profile)
    }
}

private final class RTTProbeCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<UInt32?, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<UInt32?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func resume(_ value: UInt32?) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}
