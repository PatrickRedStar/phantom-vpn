//
//  AdminConsoleView.swift
//  GhostStream (macOS)
//
//  «Админ» (mockup.html, pane admin): нативная Table клиентов сервера,
//  детали выбранного — в `.inspector`, «Новый клиент» — в тулбаре.
//  Поверх общего PhantomKit `AdminViewModel` (mTLS + TOFU). API живёт за
//  туннелем, поэтому опрос — только в `.connected`.
//

import AppKit
import CryptoKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct AdminConsoleView: View {

    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles
    @Environment(VpnStateManager.self) private var stateMgr

    @State private var vm: AdminViewModel?
    @State private var vmProfileId: String?
    /// SHA-256 серта активного профиля — так сервер отдаёт `fingerprint`.
    @State private var ownFingerprint: String?
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator(\ClientRow.name)]
    @State private var showCreate = false
    @State private var pending: PendingAction?
    @State private var notice: AdminNotice?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: GsSpace.s) {
            content
        }
        .padding(.horizontal, GsSpace.xxl)
        .padding(.top, GsSpace.s)
        .padding(.bottom, GsSpace.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            if let vm, adminReachable, !vm.mtlsUnavailable {
                ToolbarItem(placement: .primaryAction) {
                    Button { showCreate = true } label: {
                        Label(L("adm.new"), systemImage: "plus")
                            .labelStyle(.titleAndIcon)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
        }
        .inspector(isPresented: Binding(
            get: { adminReachable && vm?.mtlsUnavailable == false && selectedClient != nil },
            set: { if !$0 { selection = nil } }
        )) {
            if let vm, let client = selectedClient {
                AdminClientDetailPanel(
                    vm: vm,
                    client: client,
                    isOwn: isOwn(client),
                    onRequest: { handle($0, client) },
                    onStatus: { notice = AdminNotice(text: $0, isError: !$1) }
                )
                .inspectorColumnWidth(min: 250, ideal: 270, max: 380)
            }
        }
        .sheet(isPresented: $showCreate) {
            if let vm {
                AdminCreateClientSheet(vm: vm) { notice = AdminNotice(text: $0, isError: !$1) }
            }
        }
        .alert(
            pending.map { $0.title } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(action.buttonTitle, role: .destructive) { perform(action) }
            Button(L("general.cancel"), role: .cancel) {}
        } message: { action in
            Text(isOwn(action.client)
                 ? L("adm.confirm.self") + "\n\n" + action.message
                 : action.message)
        }
        .task(id: notice) {
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            notice = nil
        }
        // VM живёт per-profile: смена активного профиля = новый mTLS-клиент.
        // Опрос раз в 30 с, только пока вкладка открыта и туннель в
        // .connected: API на 10.7.0.1 за туннелем, без него — таймауты, а
        // TOFU мог бы закрепить чужой хост из LAN.
        .task(id: "\(profiles.activeId ?? "")|\(adminReachable)") {
            rebuildViewModel()
            while adminReachable, !Task.isCancelled {
                await vm?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let vm {
            if vm.mtlsUnavailable {
                placeholder(L("adm.unavailable.title"), L("adm.unavailable.text"))
            } else if !adminReachable {
                placeholder(L("adm.offline.title"), L("adm.offline.text"))
            } else if vm.clients.isEmpty, let error = vm.error {
                placeholder(L("adm.error.title"), error, retry: true)
            } else if vm.clients.isEmpty {
                if vm.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { placeholder(L("adm.empty"), nil) }
            } else {
                table(vm)
                if let notice {
                    Text(notice.text)
                        .gsType(.caption)
                        .foregroundStyle(notice.isError ? C.danger : C.textDim)
                        .padding(.horizontal, GsSpace.s)
                }
            }
        } else {
            placeholder(L("adm.no_profile"), nil)
        }
    }

    private func placeholder(_ title: String, _ text: String?, retry: Bool = false) -> some View {
        VStack(spacing: GsSpace.m) {
            Text(title)
                .gsType(.title)
                .foregroundStyle(C.bone)
            if let text {
                Text(text)
                    .gsType(.body)
                    .foregroundStyle(C.textDim)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if retry {
                Button(L("action.retry")) { Task { await vm?.refresh() } }
                    .controlSize(.large)
                    .gsGlassButton()
                    .padding(.top, GsSpace.s)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func table(_ vm: AdminViewModel) -> some View {
        let rows = rows(vm)
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L("adm.col.client"), value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).lineLimit(1)
                    Text(row.ip)
                        .font(.custom(GsFontName.jetBrainsMono, size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, GsSpace.xs)
            }
            .width(min: 120, ideal: 150)

            TableColumn(L("adm.col.status"), value: \.statusSort) { row in
                AdminClientStatus(client: row.client)
            }
            .width(min: 150, ideal: 190)

            TableColumn(L("adm.col.access"), value: \.accessSort) { row in
                let access = AdminFormat.access(row.client.expiresAt)
                Text(access.text)
                    .monospacedDigit()
                    .foregroundStyle(access.dim ? .secondary : .primary)
            }
            .width(min: 80, ideal: 96)

            TableColumn(L("adm.col.traffic"), value: \.traffic) { row in
                Text(AdminFormat.bytes(row.traffic)).monospacedDigit()
            }
            .width(min: 60, ideal: 76)
        }
        .gsType(.body)
        .tableStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(C.bgElev, in: RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous).stroke(C.hair, lineWidth: 1))
        .frame(maxHeight: GsTable.height(rows: rows.count, rowHeight: GsTable.twoLineRow))
        .contextMenu(forSelectionType: String.self) { names in
            if let client = names.first.flatMap(client(named:)) {
                AdminActionsMenu(client: client) { handle($0, client) }
            }
        }
    }

    // MARK: - Actions

    /// Разрушительное — через подтверждение, остальное — сразу.
    private func handle(_ request: AdminRequest, _ client: AdminClient) {
        switch request {
        case .disable:      pending = PendingAction(kind: .disable, client: client)
        case .revokeAdmin:  pending = PendingAction(kind: .revoke, client: client)
        case .delete:       pending = PendingAction(kind: .delete, client: client)
        case .enable:
            run(L("admin.status.enabled")) { try await $0.setEnabled(name: client.name, enabled: true) }
        case .makeAdmin:
            run(L("admin.status.admin_toggled")) { try await $0.setAdmin(name: client.name, isAdmin: true) }
        case .extend30:
            run(L("admin.status.extended")) {
                try await $0.manageSubscription(name: client.name, action: "extend", days: 30)
            }
        case .copyLink:
            Task {
                do {
                    let link = try await vm?.getConnString(name: client.name) ?? ""
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                    notice = AdminNotice(text: L("adm.copied"))
                } catch {
                    notice = AdminNotice(text: error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func perform(_ action: PendingAction) {
        let name = action.client.name
        switch action.kind {
        case .disable:
            run(L("admin.status.disabled")) { try await $0.setEnabled(name: name, enabled: false) }
        case .revoke:
            run(L("admin.status.admin_toggled")) { try await $0.setAdmin(name: name, isAdmin: false) }
        case .delete:
            if selection == name { selection = nil }
            run(L("admin.status.deleted")) { try await $0.deleteClient(name: name) }
        }
    }

    private func run(_ success: String, _ op: @escaping (AdminViewModel) async throws -> Void) {
        guard let vm else { return }
        Task {
            do {
                try await op(vm)
                notice = AdminNotice(text: success)
            } catch {
                notice = AdminNotice(text: error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - Model

    private var adminReachable: Bool { stateMgr.statusFrame.state == .connected }

    private var selectedClient: AdminClient? { selection.flatMap(client(named:)) }

    private func client(named name: String) -> AdminClient? {
        vm?.clients.first { $0.name == name }
    }

    private func isOwn(_ client: AdminClient) -> Bool {
        guard let ownFingerprint else { return false }
        return client.fingerprint.lowercased().filter { $0 != ":" } == ownFingerprint
    }

    private func rows(_ vm: AdminViewModel) -> [ClientRow] {
        vm.clients
            .map { ClientRow(client: $0, isOwn: isOwn($0)) }
            .sorted(using: sortOrder)
    }

    private func rebuildViewModel() {
        guard let profile = profiles.activeProfile else {
            vm = nil
            vmProfileId = nil
            return
        }
        if vmProfileId == profile.id, vm != nil { return }
        let model = AdminViewModel(profile: profile, profilesStore: profiles)
        vm = model
        vmProfileId = profile.id
        ownFingerprint = Self.certFingerprint(profile.certPem)
        selection = nil
        #if DEBUG
        if DebugDemo.isActive {
            model._previewApply(status: nil, clients: AdminDemo.clients, error: nil, mtls: false)
            ownFingerprint = AdminDemo.ownFingerprint
            selection = AdminDemo.selected
        }
        #endif
    }

    /// SHA-256 DER первого сертификата PEM, hex — формат `fingerprint`
    /// сервера (`vpn_session::cert_fingerprint`).
    static func certFingerprint(_ pem: String?) -> String? {
        guard let body = pem?
            .components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().first?
            .components(separatedBy: "-----END CERTIFICATE-----").first,
            let der = Data(base64Encoded: body.filter { !$0.isWhitespace })
        else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Rows and actions

private struct ClientRow: Identifiable {
    let client: AdminClient
    let isOwn: Bool

    var id: String { client.name }
    var name: String { client.name }
    var ip: String { String(client.tunAddr.split(separator: "/").first ?? "") }
    var traffic: Int64 { client.bytesRx + client.bytesTx }
    var accessSort: Int64 { client.expiresAt ?? .max }
    var statusSort: Int { AdminClientState(client).rawValue }

    @MainActor var title: String { isOwn ? String(format: L("adm.you"), client.name) : client.name }
}

private struct AdminNotice: Equatable {
    let text: String
    var isError = false
}

/// Действие над клиентом из меню строки или инспектора.
enum AdminRequest {
    case extend30, copyLink, enable, disable, makeAdmin, revokeAdmin, delete
}

private struct PendingAction {
    enum Kind { case disable, revoke, delete }
    let kind: Kind
    let client: AdminClient

    @MainActor var title: String {
        switch kind {
        case .disable: return String(format: L("adm.confirm.disable"), client.name)
        case .revoke:  return String(format: L("adm.confirm.revoke"), client.name)
        case .delete:  return String(format: L("adm.confirm.delete"), client.name)
        }
    }

    @MainActor var message: String {
        switch kind {
        case .disable: return L("adm.confirm.disable.text")
        case .revoke:  return L("adm.confirm.revoke.text")
        case .delete:  return L("adm.confirm.delete.text")
        }
    }

    @MainActor var buttonTitle: String {
        switch kind {
        case .disable: return L("adm.do.disable")
        case .revoke:  return L("adm.do.revoke")
        case .delete:  return L("adm.do.delete")
        }
    }
}

/// Пункты меню строки (контекстное меню таблицы).
struct AdminActionsMenu: View {
    let client: AdminClient
    let onRequest: (AdminRequest) -> Void

    var body: some View {
        Button(L("adm.extend30")) { onRequest(.extend30) }
        Button(L("adm.copy_link")) { onRequest(.copyLink) }
        Divider()
        if client.enabled {
            Button(L("adm.disable")) { onRequest(.disable) }
        } else {
            Button(L("adm.enable")) { onRequest(.enable) }
        }
        if client.isAdmin {
            Button(L("adm.revoke_admin")) { onRequest(.revokeAdmin) }
        } else {
            Button(L("adm.make_admin")) { onRequest(.makeAdmin) }
        }
        Divider()
        Button(L("adm.delete"), role: .destructive) { onRequest(.delete) }
    }
}

// MARK: - Status

/// Состояние клиента; порядок — порядок сортировки.
enum AdminClientState: Int {
    case online, offline, expired, disabled

    init(_ client: AdminClient) {
        if !client.enabled {
            self = .disabled
        } else if let exp = client.expiresAt, exp <= Int64(Date().timeIntervalSince1970) {
            self = .expired
        } else {
            self = client.connected ? .online : .offline
        }
    }
}

/// Точка + слово: «В сети», «Не в сети · 2 ч назад», «Отключён».
struct AdminClientStatus: View {
    let client: AdminClient

    @Environment(\.gsColors) private var C

    var body: some View {
        let state = AdminClientState(client)
        HStack(spacing: 7) {
            Circle()
                .fill(color(state))
                .frame(width: 8, height: 8)
            Text(text(state))
                .lineLimit(1)
        }
    }

    private func color(_ state: AdminClientState) -> Color {
        switch state {
        case .online:   return C.signal
        case .offline:  return C.textFaint
        case .expired:  return C.warn
        case .disabled: return C.danger
        }
    }

    private func text(_ state: AdminClientState) -> String {
        switch state {
        case .online:   return L("adm.online")
        case .expired:  return L("adm.expired")
        case .disabled: return L("adm.disabled")
        case .offline:
            guard let ago = AdminFormat.ago(client.lastSeenSecs) else { return L("adm.offline") }
            return String(format: L("adm.offline.ago"), ago)
        }
    }
}

// MARK: - Formatting

enum AdminFormat {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// «2 ч назад».
    static func ago(_ secs: Int64?) -> String? {
        guard let secs, secs > 0 else { return nil }
        return Date(timeIntervalSinceNow: -TimeInterval(secs))
            .formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    @MainActor
    static func access(_ expiresAt: Int64?) -> (text: String, dim: Bool) {
        guard let expiresAt else { return (L("adm.forever"), true) }
        let date = Date(timeIntervalSince1970: TimeInterval(expiresAt))
        if date < .now {
            return (String(format: L("adm.expired.on"),
                           date.formatted(.dateTime.day(.twoDigits).month(.twoDigits))), true)
        }
        return (date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year()), false)
    }
}

// MARK: - Demo

#if DEBUG
/// Клиенты для `-gsDemo` (как в макете), только в памяти.
enum AdminDemo {
    static let ownFingerprint = "aa11"
    static let selected = "Аня"

    static var clients: [AdminClient] {
        let now = Int64(Date().timeIntervalSince1970)
        let rows: [[String: Any]] = [
            client("Пётр", fp: ownFingerprint, ip: 12, online: true, rx: 40_100_000_000, tx: 4_800_000_000,
                   expires: NSNull(), admin: true),
            client("Мама", fp: "bb22", ip: 14, online: true, rx: 2_900_000_000, tx: 520_000_000,
                   expires: now + 45 * 86_400),
            client("Аня", fp: "cc33", ip: 17, online: false, rx: 11_400_000_000, tx: 1_900_000_000,
                   expires: now + 33 * 86_400, lastSeen: 7_200),
            client("Старый ноутбук", fp: "dd44", ip: 21, online: false, rx: 0, tx: 0,
                   expires: now - 58 * 86_400, enabled: false, lastSeen: 5_000_000),
        ]
        let data = try! JSONSerialization.data(withJSONObject: rows)
        return try! JSONDecoder().decode([AdminClient].self, from: data)
    }

    static var stats: [ClientStat] {
        let now = Int64(Date().timeIntervalSince1970)
        var rx: Int64 = 0
        let rows: [[String: Any]] = (0..<24).map { h in
            rx += Int64(200_000_000 + 180_000_000 * sin(Double(h) / 3))
            return ["ts": now - Int64(24 - h) * 3_600, "bytes_rx": rx, "bytes_tx": rx / 9]
        }
        return try! JSONDecoder().decode([ClientStat].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    static var logs: [ClientLog] {
        let now = Int64(Date().timeIntervalSince1970)
        let rows: [[String: Any]] = [
            ["ts": now - 9_000, "dst": "api.telegram.org", "port": 443, "proto": "tcp", "bytes": 4_200_000],
            ["ts": now - 8_400, "dst": "rr3.googlevideo.com", "port": 443, "proto": "udp", "bytes": 310_000_000],
            ["ts": now - 7_900, "dst": "instagram.com", "port": 443, "proto": "tcp", "bytes": 18_000_000],
        ]
        return try! JSONDecoder().decode([ClientLog].self, from: JSONSerialization.data(withJSONObject: rows))
    }

    private static func client(_ name: String, fp: String, ip: Int, online: Bool, rx: Int64, tx: Int64,
                               expires: Any, admin: Bool = false, enabled: Bool = true,
                               lastSeen: Int64 = 1) -> [String: Any] {
        ["name": name, "fingerprint": fp, "tun_addr": "10.7.0.\(ip)/24", "enabled": enabled,
         "connected": online, "bytes_rx": rx, "bytes_tx": tx, "created_at": "2026-03-14T10:00:00Z",
         "last_seen_secs": lastSeen, "expires_at": expires, "is_admin": admin]
    }
}
#endif
