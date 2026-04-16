//
//  AdminView.swift
//  GhostStream
//
//  Admin screen — server status + client list + create-client sheet.
//  Pushed from Settings with an active `VpnProfile`.
//

import SwiftUI

// MARK: - AdminView

/// Top-level Admin screen. Shows a server-status card and a scrollable list
/// of all clients; tapping a row navigates to `ClientDetailView`; the
/// bottom CTA opens `CreateClientSheet`.
///
/// Expected to be pushed inside an existing `NavigationStack` from Settings.
public struct AdminView: View {

    @Environment(\.gsColors) private var C
    @State private var vm: AdminViewModel
    @State private var showCreateSheet = false
    @State private var toastMessage: String?

    /// - Parameter profile: profile supplying the admin mTLS credentials.
    public init(profile: VpnProfile) {
        _vm = State(initialValue: AdminViewModel(profile: profile))
    }

    /// Alternate init for previews / tests — inject a pre-built VM.
    init(viewModel: AdminViewModel) {
        _vm = State(initialValue: viewModel)
    }

    public var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if vm.mtlsUnavailable {
                        mtlsBanner
                    } else if let err = vm.error, vm.status == nil {
                        errorBanner(err)
                    }

                    statusCard
                    clientsList
                    createButton
                        .padding(.top, 8)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .refreshable {
                await vm.refresh()
            }

            // Lightweight toast overlay
            if let toastMessage {
                VStack {
                    Spacer()
                    Text(toastMessage)
                        .gsFont(.labelMonoSmall)
                        .foregroundColor(C.bg)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(C.signal)
                        )
                        .padding(.bottom, 32)
                }
                .transition(.opacity)
            }
        }
        .navigationTitle("ADMIN")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    if vm.loading {
                        ProgressView().tint(C.signal)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(C.signal)
                    }
                }
                .disabled(vm.loading)
            }
        }
        .task {
            await vm.refresh()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateClientSheet(viewModel: vm)
        }
    }

    // MARK: - Subviews

    private var mtlsBanner: some View {
        GhostCard(bg: C.danger.opacity(0.08), border: C.danger) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MTLS UNAVAILABLE")
                    .gsFont(.labelMono)
                    .foregroundColor(C.danger)
                Text("iOS URLSession не принимает Ed25519 client-сертификаты. Перевыпусти admin-cert через phantom-keygen с --key-type ecdsa (P-256).")
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        GhostCard(bg: C.danger.opacity(0.08), border: C.danger) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ERROR")
                    .gsFont(.labelMono)
                    .foregroundColor(C.danger)
                Text(message)
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusCard: some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("SERVER STATUS")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textDim)

                if let s = vm.status {
                    kvRow(label: "UPTIME",   value: AdminFormat.duration(s.uptimeSecs))
                    kvRow(label: "SESSIONS", value: "\(s.activeSessions)")
                    kvRow(label: "EXIT IP",  value: s.serverIp ?? "—")
                } else {
                    Text(vm.loading ? "LOADING…" : "NO DATA")
                        .gsFont(.valueMono)
                        .foregroundColor(C.textFaint)
                }
            }
        }
    }

    private func kvRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .gsFont(.labelMonoSmall)
                .foregroundColor(C.textDim)
            Spacer()
            Text(value)
                .gsFont(.valueMono)
                .foregroundColor(C.bone)
        }
    }

    private var clientsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLIENTS (\(vm.clients.count))")
                .gsFont(.labelMono)
                .foregroundColor(C.textDim)
                .padding(.leading, 2)

            if vm.clients.isEmpty && !vm.loading {
                GhostCard {
                    Text("NO CLIENTS")
                        .gsFont(.labelMonoSmall)
                        .foregroundColor(C.textFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.clients) { client in
                        NavigationLink(
                            destination: ClientDetailView(client: client, adminVM: vm)
                        ) {
                            ClientRowView(client: client)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var createButton: some View {
        Button {
            showCreateSheet = true
        } label: {
            HStack {
                Image(systemName: "plus")
                Text("CREATE CLIENT")
                    .gsFont(.fabText)
            }
            .foregroundColor(C.bg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(C.signal)
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.mtlsUnavailable)
        .opacity(vm.mtlsUnavailable ? 0.4 : 1.0)
    }
}

// MARK: - ClientRowView

/// Single row in the Admin clients list.
struct ClientRowView: View {

    let client: AdminClient

    @Environment(\.gsColors) private var C

    var body: some View {
        GhostCard(active: client.connected) {
            HStack(alignment: .top, spacing: 12) {
                // Connection dot
                Circle()
                    .fill(client.connected ? C.signal : C.textFaint)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(client.name)
                            .gsFont(.clientName)
                            .foregroundColor(C.bone)
                        if client.isAdmin {
                            AdminBadge()
                        }
                        if !client.enabled {
                            DisabledBadge()
                        }
                    }

                    HStack(spacing: 6) {
                        Text(client.tunAddr)
                            .gsFont(.labelMonoSmall)
                            .foregroundColor(C.textDim)
                        Text("·")
                            .gsFont(.labelMonoSmall)
                            .foregroundColor(C.textFaint)
                        Text("↓\(AdminFormat.bytes(client.bytesRx)) ↑\(AdminFormat.bytes(client.bytesTx))")
                            .gsFont(.labelMonoSmall)
                            .foregroundColor(C.textDim)
                        Text("·")
                            .gsFont(.labelMonoSmall)
                            .foregroundColor(C.textFaint)
                        Text(AdminFormat.subscriptionShort(client.expiresAt))
                            .gsFont(.labelMonoSmall)
                            .foregroundColor(AdminFormat.subscriptionColor(client.expiresAt, C: C))
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .foregroundColor(C.textFaint)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - AdminBadge / DisabledBadge

/// "ADMIN" pill — Departure Mono micro label, `C.warn` background.
struct AdminBadge: View {
    @Environment(\.gsColors) private var C
    var body: some View {
        Text("ADMIN")
            .gsFont(.labelMonoSmall)
            .foregroundColor(C.bg)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(C.warn)
            )
    }
}

/// "OFF" pill for disabled clients.
struct DisabledBadge: View {
    @Environment(\.gsColors) private var C
    var body: some View {
        Text("OFF")
            .gsFont(.labelMonoSmall)
            .foregroundColor(C.textDim)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(C.hairBold, lineWidth: 1)
            )
    }
}

// MARK: - Formatters

/// Static helpers for byte / duration / subscription formatting used by the
/// Admin screens. Kept in one place so client-row and detail-view agree.
enum AdminFormat {

    /// "1.2 MB" / "512 KB" / "42 B"
    static func bytes(_ n: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        fmt.countStyle = .binary
        return fmt.string(fromByteCount: n)
    }

    /// "3d 4h 12m" / "42m 17s" — server uptime.
    static func duration(_ secs: Int64) -> String {
        let s = max(0, secs)
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if d > 0 { return "\(d)d \(h)h \(m)m" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(sec)s" }
        return "\(sec)s"
    }

    /// "∞" / "exp 23d" / "EXPIRED" — for list rows.
    static func subscriptionShort(_ expiresAt: Int64?) -> String {
        guard let exp = expiresAt else { return "∞" }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return "EXPIRED" }
        let days = Int(delta / 86400)
        if days >= 2 { return "exp \(days)d" }
        let hours = Int(delta / 3600)
        return "exp \(hours)h"
    }

    /// Colour for subscription label — danger if expired / <3d, warn if <7d.
    static func subscriptionColor(_ expiresAt: Int64?, C: GsColorSet) -> Color {
        guard let exp = expiresAt else { return C.textDim }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return C.danger }
        if delta < 3 * 86400 { return C.danger }
        if delta < 7 * 86400 { return C.warn }
        return C.textDim
    }

    /// "2025-04-16 14:23 UTC" absolute formatting.
    static func absoluteDate(_ unix: Int64) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    /// "23d left" / "EXPIRED" — for detail view.
    static func subscriptionLong(_ expiresAt: Int64?) -> String {
        guard let exp = expiresAt else { return "Бессрочно" }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return "Истекло" }
        let days = Int(delta / 86400)
        let hours = Int((delta % 86400) / 3600)
        if days >= 1 { return "\(days)d \(hours)h осталось" }
        return "\(hours)h осталось"
    }

    /// "12s" / "3m" / "—" for last-seen.
    static func lastSeen(_ secs: Int64?) -> String {
        guard let s = secs else { return "—" }
        if s < 60 { return "\(s)s назад" }
        if s < 3600 { return "\(s / 60)m назад" }
        if s < 86400 { return "\(s / 3600)h назад" }
        return "\(s / 86400)d назад"
    }
}

// MARK: - Previews

#Preview("AdminView — populated") {
    NavigationStack {
        AdminView(viewModel: AdminPreviewData.populatedVM())
    }
    .gsTheme(override: .dark)
}

#Preview("AdminView — mTLS blocked") {
    NavigationStack {
        AdminView(viewModel: AdminPreviewData.mtlsBlockedVM())
    }
    .gsTheme(override: .dark)
}
