//
//  AdminConsoleView.swift
//  GhostStream (macOS)
//
//  ADMIN tab — desktop port of the iOS Admin screen on top of the shared
//  PhantomKit `AdminViewModel` / `AdminHttpClient` (mTLS + TOFU pin, admin
//  gateway derived from the profile tun address, reachable only through the
//  tunnel).
//
//  Layout (matches the approved HTML mockup):
//   1. detail-head: "CLIENTS · N" + hero "admin." + mTLS/pin status right.
//   2. stats strip: uptime / sessions / total traffic / exit IP.
//   3. columns: clients Table (left) + selected-client detail panel (right)
//      with traffic sparkline, recent destinations and subscription actions.
//   4. footer CTA: + NEW CLIENT → CreateClientSheet.
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct AdminConsoleView: View {

    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles

    @State private var vm: AdminViewModel?
    @State private var vmProfileId: String?
    @State private var selectedClientName: String?
    @State private var showCreateSheet = false
    @State private var banner: AdminBannerState?
    @State private var bannerTtlTask: Task<Void, Never>?
    @State private var confirmDeleteClient: AdminClient?
    @State private var sortOrder: [KeyPathComparator<AdminClientRow>] = [
        .init(\.name, order: .forward)
    ]

    private struct AdminBannerState: Equatable {
        enum Kind { case success, info, error }
        let message: String
        let kind: Kind
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            detailHead
            if let vm {
                if vm.mtlsUnavailable {
                    mtlsBanner(vm.error)
                } else {
                    if let err = vm.error, vm.status == nil {
                        errorBanner(err)
                    }
                    statsStrip(vm)
                    contentColumns(vm)
                    footer(vm)
                }
            } else {
                noProfileState
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
        .sheet(isPresented: $showCreateSheet) {
            if let vm {
                AdminCreateClientSheet(vm: vm) { message, ok in
                    setBanner(message, kind: ok ? .success : .error)
                }
            }
        }
        .alert(
            item: $confirmDeleteClient
        ) { client in
            Alert(
                title: Text(String(format: L("admin.confirm.delete"), client.name)),
                message: Text(L("admin.confirm.delete.hint")),
                primaryButton: .destructive(Text(L("admin.action.delete"))) {
                    run(L("admin.status.deleted")) { vm in
                        try await vm.deleteClient(name: client.name)
                        if selectedClientName == client.name { selectedClientName = nil }
                    }
                },
                secondaryButton: .cancel(Text(L("general.cancel")))
            )
        }
        // VM живёт per-profile: смена активного профиля = новый identity/PEM
        // = новый mTLS-клиент. Пересобираем и перечитываем.
        .task(id: profiles.activeId) {
            rebuildViewModel()
            await vm?.refresh()
        }
        // Лёгкий автопул как у roster probe — раз в 30 с, только пока
        // вкладка смонтирована.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                await vm?.refresh()
            }
        }
        .onDisappear {
            bannerTtlTask?.cancel()
        }
    }

    // MARK: - VM lifecycle

    private func rebuildViewModel() {
        guard let profile = profiles.activeProfile else {
            vm = nil
            vmProfileId = nil
            return
        }
        if vmProfileId == profile.id, vm != nil { return }
        vm = AdminViewModel(profile: profile, profilesStore: profiles)
        vmProfileId = profile.id
        selectedClientName = nil
    }

    // MARK: - 1. detail-head

    @ViewBuilder
    private var detailHead: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(L("admin.head.meta")) · \(vm?.clients.count ?? 0)")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.20 * 11)
                    .foregroundStyle(C.textFaint)
                HStack(spacing: 0) {
                    Text("admin")
                        .font(.custom("InstrumentSerif-Italic", size: 38))
                        .foregroundStyle(C.signal)
                    Text(".")
                        .font(.custom("SpaceGrotesk-Bold", size: 38))
                        .foregroundStyle(C.textDim)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    PulseDot(
                        color: vm?.mtlsUnavailable == false ? C.signal : C.textDim,
                        size: 8,
                        pulse: false
                    )
                    Text(headStatusText)
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .tracking(0.16 * 10.5)
                        .foregroundStyle(C.textDim)
                }
                refreshButton
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            DashedHairline()
        }
    }

    private var headStatusText: String {
        guard let vm else { return L("admin.head.no_profile") }
        if vm.mtlsUnavailable { return L("admin.head.mtls_off") }
        let host = AdminGateway.host(forTunAddr: vm.profile.tunAddr)
        let pin = vm.profile.cachedAdminServerCertFp == nil ? "TOFU" : "PIN OK"
        return "MTLS · \(host):8080 · \(pin)"
    }

    @ViewBuilder
    private var refreshButton: some View {
        Button {
            Task { await vm?.refresh() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: vm?.loading == true ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 10))
                Text(L("admin.refresh"))
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.14 * 10)
            }
            .foregroundStyle(C.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .gsStroke(C.hairBold, GsRadius.control)
            .contentShape(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(vm == nil || vm?.loading == true)
        .keyboardShortcut("r", modifiers: .command)
    }

    // MARK: - Banners

    @ViewBuilder
    private func mtlsBanner(_ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("admin.mtls.unavailable"))
                .font(.custom("SpaceGrotesk-Bold", size: 14))
                .foregroundStyle(C.danger)
            Text(detail ?? L("admin.mtls.hint"))
                .font(.custom("JetBrainsMono-Regular", size: 11))
                .foregroundStyle(C.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev))
        .gsStroke(C.danger.opacity(0.35), GsRadius.card)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("admin.error"))
                    .font(.custom("SpaceGrotesk-Bold", size: 13))
                    .foregroundStyle(C.danger)
                Text(message)
                    .font(.custom("JetBrainsMono-Regular", size: 10.5))
                    .foregroundStyle(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await vm?.refresh() }
            } label: {
                Text(L("admin.retry"))
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.14 * 10)
                    .foregroundStyle(C.signal)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .gsStroke(C.signal, GsRadius.control)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev))
        .gsStroke(C.danger.opacity(0.35), GsRadius.card)
    }

    @ViewBuilder
    private var noProfileState: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.system(size: 36))
                .foregroundStyle(C.textFaint)
            Text(L("admin.head.no_profile"))
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .foregroundStyle(C.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev2))
        .gsStroke(C.hair, GsRadius.card)
    }

    // MARK: - 2. stats strip

    @ViewBuilder
    private func statsStrip(_ vm: AdminViewModel) -> some View {
        HStack(spacing: 10) {
            statCell(
                label: L("admin.uptime"),
                value: vm.status.map { AdminConsoleFormat.duration($0.uptimeSecs) } ?? "—"
            )
            statCell(
                label: L("admin.sessions"),
                value: vm.status.map { "\($0.activeSessions)" } ?? "—",
                signal: (vm.status?.activeSessions ?? 0) > 0
            )
            statCell(
                label: L("admin.egress"),
                value: AdminConsoleFormat.bytes(
                    vm.clients.reduce(Int64(0)) { $0 + $1.bytesRx + $1.bytesTx }
                )
            )
            statCell(
                label: L("admin.exit_ip"),
                value: vm.status?.exitIp ?? vm.status?.serverIp ?? "—",
                mono: true
            )
        }
    }

    private func statCell(
        label: String,
        value: String,
        signal: Bool = false,
        mono: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.custom("DepartureMono-Regular", size: 9.5))
                .tracking(0.14 * 9.5)
                .foregroundStyle(C.textFaint)
            Text(value)
                .font(mono
                      ? .custom("JetBrainsMono-Regular", size: 14)
                      : .custom("SpaceGrotesk-Bold", size: 19))
                .foregroundStyle(signal ? C.signal : C.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev))
        .gsStroke(C.hair, GsRadius.card)
    }

    // MARK: - 3. columns

    @ViewBuilder
    private func contentColumns(_ vm: AdminViewModel) -> some View {
        HStack(alignment: .top, spacing: 14) {
            clientsTable(vm)
            if let client = selectedClient(vm) {
                AdminClientDetailPanel(
                    vm: vm,
                    client: client,
                    onStatus: { message, ok in
                        setBanner(message, kind: ok ? .success : .error)
                    },
                    onDelete: { confirmDeleteClient = client }
                )
                .frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func selectedClient(_ vm: AdminViewModel) -> AdminClient? {
        guard let name = selectedClientName else { return nil }
        return vm.clients.first { $0.name == name }
    }

    @ViewBuilder
    private func clientsTable(_ vm: AdminViewModel) -> some View {
        if vm.clients.isEmpty && !vm.loading {
            VStack(alignment: .center, spacing: 14) {
                Image(systemName: "person.slash")
                    .font(.system(size: 30))
                    .foregroundStyle(C.textFaint)
                Text(L("admin.no.clients"))
                    .font(.custom("JetBrainsMono-Regular", size: 12))
                    .foregroundStyle(C.textDim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
            .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev2))
            .gsStroke(C.hair, GsRadius.card)
        } else {
            Table(rows(vm), sortOrder: $sortOrder) {
                TableColumn(L("admin.col.client"), value: \.name) { row in
                    clientCell(row)
                }
                .width(min: 140)

                TableColumn("tun", value: \.tunAddr) { row in
                    selectableCell(row) {
                        Text(row.tunAddr)
                            .font(.custom("JetBrainsMono-Regular", size: 11))
                            .foregroundStyle(C.textDim)
                    }
                }
                .width(90)

                TableColumn(L("admin.col.status"), value: \.statusSort) { row in
                    selectableCell(row) {
                        AdminStatusChip(chip: row.chip)
                    }
                }
                .width(110)

                TableColumn("rx / tx", value: \.trafficSort) { row in
                    selectableCell(row) {
                        Text("\(AdminConsoleFormat.bytes(row.bytesRx)) / \(AdminConsoleFormat.bytes(row.bytesTx))")
                            .font(.custom("JetBrainsMono-Regular", size: 10.5))
                            .foregroundStyle(C.textDim)
                    }
                }
                .width(150)

                TableColumn(L("admin.col.subscription"), value: \.subscriptionSort) { row in
                    selectableCell(row) {
                        Text(AdminConsoleFormat.subscriptionShort(row.expiresAt))
                            .font(.custom("JetBrainsMono-Regular", size: 11))
                            .foregroundStyle(AdminConsoleFormat.subscriptionColor(row.expiresAt, C: C))
                    }
                }
                .width(110)

                TableColumn("") { row in
                    rowMenu(vm, row)
                }
                .width(30)
            }
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous).fill(C.bgElev))
            .gsClip(GsRadius.card)
            .gsStroke(C.hair, GsRadius.card)
        }
    }

    @ViewBuilder
    private func clientCell(_ row: AdminClientRow) -> some View {
        selectableCell(row) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.custom("SpaceGrotesk-Bold", size: 13))
                        .foregroundStyle(C.bone)
                    if row.isAdmin {
                        Text("ADMIN")
                            .font(.custom("DepartureMono-Regular", size: 8.5))
                            .tracking(0.10 * 8.5)
                            .foregroundStyle(C.signal)
                    }
                }
                if row.selected {
                    Text("● \(L("admin.selected"))")
                        .font(.custom("DepartureMono-Regular", size: 9))
                        .tracking(0.14 * 9)
                        .foregroundStyle(C.signal)
                }
            }
            .padding(.leading, row.selected ? 6 : 0)
            .overlay(alignment: .leading) {
                if row.selected {
                    Rectangle().fill(C.signal).frame(width: 2)
                }
            }
        }
    }

    @ViewBuilder
    private func selectableCell<Content: View>(
        _ row: AdminClientRow,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedClientName = selectedClientName == row.name ? nil : row.name
            }
            .contextMenu {
                if let vm { rowMenuCommands(vm, row) }
            }
    }

    @ViewBuilder
    private func rowMenu(_ vm: AdminViewModel, _ row: AdminClientRow) -> some View {
        Menu {
            rowMenuCommands(vm, row)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(C.textFaint)
                .font(.system(size: 14))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .accessibilityLabel("Client actions")
    }

    @ViewBuilder
    private func rowMenuCommands(_ vm: AdminViewModel, _ row: AdminClientRow) -> some View {
        Button(row.enabled ? L("admin.action.disable") : L("admin.action.enable")) {
            run(row.enabled ? L("admin.status.disabled") : L("admin.status.enabled")) { vm in
                try await vm.setEnabled(name: row.name, enabled: !row.enabled)
            }
        }
        Button(L("admin.action.extend30")) {
            run(L("admin.status.extended")) { vm in
                try await vm.manageSubscription(name: row.name, action: "extend", days: 30)
            }
        }
        Button(L("admin.action.copy_ghs")) {
            Task {
                do {
                    let ghs = try await vm.getConnString(name: row.name)
                    copyToPasteboard(ghs)
                    setBanner(L("admin.status.ghs_copied"), kind: .info)
                } catch {
                    setBanner(error.localizedDescription, kind: .error)
                }
            }
        }
        Button(row.isAdmin ? L("admin.action.revoke_admin") : L("admin.action.make_admin")) {
            run(L("admin.status.admin_toggled")) { vm in
                try await vm.setAdmin(name: row.name, isAdmin: !row.isAdmin)
            }
        }
        Divider()
        Button(L("admin.action.delete"), role: .destructive) {
            confirmDeleteClient = vm.clients.first { $0.name == row.name }
        }
    }

    // MARK: - 4. footer

    @ViewBuilder
    private func footer(_ vm: AdminViewModel) -> some View {
        HStack(spacing: 10) {
            Button { showCreateSheet = true } label: {
                HStack(spacing: 8) {
                    Text(L("admin.new.client"))
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.18 * 11)
                    Text("· ⌘N")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .foregroundStyle(C.signal.opacity(0.6))
                }
                .foregroundStyle(C.signal)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .gsStroke(C.signal, GsRadius.control)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)

            Spacer()

            Text(banner?.message ?? "\(vm.clients.count) \(L("admin.head.meta")) · \(vm.clients.filter(\.connected).count) LIVE")
                .font(.custom("DepartureMono-Regular", size: 10.5))
                .tracking(0.14 * 10.5)
                .foregroundStyle(bannerColor)
        }
    }

    private var bannerColor: Color {
        guard let banner else { return C.textFaint }
        switch banner.kind {
        case .success: return C.signal
        case .info:    return C.textDim
        case .error:   return C.danger
        }
    }

    private func setBanner(_ message: String, kind: AdminBannerState.Kind) {
        banner = AdminBannerState(message: message, kind: kind)
        bannerTtlTask?.cancel()
        guard kind != .error else { return }
        let captured = banner
        bannerTtlTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if banner == captured { banner = nil }
        }
    }

    /// Runs a mutating VM action; on success shows `successMessage`,
    /// on failure surfaces the error in the status line.
    private func run(
        _ successMessage: String,
        _ action: @escaping (AdminViewModel) async throws -> Void
    ) {
        guard let vm else { return }
        Task {
            do {
                try await action(vm)
                setBanner(successMessage, kind: .success)
            } catch {
                setBanner(error.localizedDescription, kind: .error)
            }
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: - Rows

    private func rows(_ vm: AdminViewModel) -> [AdminClientRow] {
        let unsorted = vm.clients.map { client in
            AdminClientRow(client: client, selected: client.name == selectedClientName)
        }
        return unsorted.sorted(using: sortOrder)
    }
}

// MARK: - Row model

struct AdminClientRow: Identifiable {
    let name: String
    let tunAddr: String
    let enabled: Bool
    let connected: Bool
    let isAdmin: Bool
    let bytesRx: Int64
    let bytesTx: Int64
    let expiresAt: Int64?
    let lastSeenSecs: Int64?
    let selected: Bool

    var id: String { name }

    init(client: AdminClient, selected: Bool) {
        self.name = client.name
        self.tunAddr = client.tunAddr
        self.enabled = client.enabled
        self.connected = client.connected
        self.isAdmin = client.isAdmin
        self.bytesRx = client.bytesRx
        self.bytesTx = client.bytesTx
        self.expiresAt = client.expiresAt
        self.lastSeenSecs = client.lastSeenSecs
        self.selected = selected
    }

    var chip: AdminClientChip {
        if !enabled { return .off }
        if let expiresAt, expiresAt <= Int64(Date().timeIntervalSince1970) { return .expired }
        if connected { return .live }
        return .idle(hours: (lastSeenSecs ?? 0) / 3_600)
    }

    var statusSort: Int {
        switch chip {
        case .live:    return 0
        case .idle:    return 1
        case .expired: return 2
        case .off:     return 3
        }
    }

    var trafficSort: Int64 { bytesRx + bytesTx }
    var subscriptionSort: Int64 { expiresAt ?? Int64.max }
}

enum AdminClientChip: Equatable {
    case live
    case idle(hours: Int64)
    case off
    case expired
}

struct AdminStatusChip: View {
    let chip: AdminClientChip
    @Environment(\.gsColors) private var C

    var body: some View {
        let (text, color): (String, Color) = {
            switch chip {
            case .live:             return (L("admin.tag.live"), C.signal)
            case .idle(let hours):  return ("\(L("admin.tag.idle")) \(hours)h", C.textDim)
            case .off:              return (L("admin.tag.off"), C.danger)
            case .expired:          return (L("admin.tag.expired"), C.warn)
            }
        }()
        Text(text)
            .font(.custom("DepartureMono-Regular", size: 9))
            .tracking(0.12 * 9)
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .gsStroke(color.opacity(0.35), GsRadius.chip)
    }
}

// MARK: - Formatting

enum AdminConsoleFormat {
    static func bytes(_ n: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        fmt.countStyle = .binary
        return fmt.string(fromByteCount: n)
    }

    static func duration(_ secs: Int64) -> String {
        let s = max(0, secs)
        let d = s / 86_400
        let h = (s % 86_400) / 3_600
        let m = (s % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(s)s"
    }

    @MainActor
    static func subscriptionShort(_ expiresAt: Int64?) -> String {
        guard let exp = expiresAt else { return "∞" }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return L("admin.tag.expired") }
        let days = Int(delta / 86_400)
        if days >= 2 { return "\(days)d" }
        return "\(Int(delta / 3_600))h"
    }

    static func subscriptionColor(_ expiresAt: Int64?, C: GsColorSet) -> Color {
        guard let exp = expiresAt else { return C.textDim }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return C.danger }
        if delta < 3 * 86_400 { return C.danger }
        if delta < 7 * 86_400 { return C.warn }
        return C.textDim
    }

    static func lastSeen(_ secs: Int64?) -> String {
        guard let s = secs else { return "—" }
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3_600)h" }
        return "\(s / 86_400)d"
    }
}
