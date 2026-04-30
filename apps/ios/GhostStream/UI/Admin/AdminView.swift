//
//  AdminView.swift
//  GhostStream
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Top-level Admin screen.
public struct AdminView: View {

    @Environment(\.gsColors) private var C
    @State private var vm: AdminViewModel
    @State private var showCreateSheet = false
    @State private var toastMessage: String?

    public init(profile: VpnProfile) {
        _vm = State(initialValue: AdminViewModel(profile: profile))
    }

    init(viewModel: AdminViewModel) {
        _vm = State(initialValue: viewModel)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            C.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if vm.mtlsUnavailable {
                        mtlsBanner
                    } else if let err = vm.error, vm.status == nil {
                        errorBanner(err)
                    }

                    statusGrid
                    clientsList
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 104)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await vm.refresh()
            }

            createFab

            if let toastMessage {
                toast(text: toastMessage)
            }
        }
        .navigationTitle(vm.profile.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Image(systemName: vm.loading ? "hourglass" : "arrow.clockwise")
                }
                .disabled(vm.loading)
            }
        }
        .task {
            await vm.refresh()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateClientSheet(viewModel: vm)
                .presentationDetents([.medium, .large])
                .environment(\.gsColors, C)
        }
    }

    private var mtlsBanner: some View {
        GhostCard(bg: C.danger.opacity(0.08), border: C.danger) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("admin.mtls.unavailable").uppercased())
                    .gsFont(.labelMono)
                    .foregroundColor(C.danger)
                Text(L("admin.ed25519.error"))
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        GhostCard(bg: C.danger.opacity(0.08), border: C.danger) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("admin.error").uppercased())
                    .gsFont(.labelMono)
                    .foregroundColor(C.danger)
                Text(message)
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Text(L("admin.retry").uppercased())
                        .gsFont(.labelMonoSmall)
                        .foregroundColor(C.signal)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statusGrid: some View {
        HStack(spacing: 8) {
            statCell(label: L("admin.uptime"), value: vm.status.map { AdminFormat.duration($0.uptimeSecs) } ?? "—")
            statCell(label: L("admin.sessions"), value: vm.status.map { "\($0.activeSessions)" } ?? "—", signal: (vm.status?.activeSessions ?? 0) > 0)
            statCell(label: L("admin.egress"), value: AdminFormat.bytes(vm.clients.reduce(Int64(0)) { $0 + $1.bytesRx + $1.bytesTx }))
        }
    }

    private func statCell(label: String, value: String, signal: Bool = false) -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(label.uppercased())
                    .gsFont(.labelMonoSmall)
                    .foregroundColor(C.textFaint)
                Text(value)
                    .gsFont(.valueMono)
                    .foregroundColor(signal ? C.signal : C.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var clientsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(format: L("admin.clients.count"), vm.clients.count).uppercased())
                .gsFont(.labelMono)
                .foregroundColor(C.textFaint)
                .padding(.leading, 4)

            if vm.clients.isEmpty && !vm.loading {
                GhostCard {
                    Text(L("admin.no.clients").uppercased())
                        .gsFont(.labelMonoSmall)
                        .foregroundColor(C.textFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(vm.clients) { client in
                        NavigationLink(destination: ClientDetailView(client: client, adminVM: vm)) {
                            ClientRowView(client: client)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var createFab: some View {
        GhostFab(text: L("admin.new.client").uppercased(), outline: true) {
            showCreateSheet = true
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(C.bg)
        .disabled(vm.mtlsUnavailable)
        .opacity(vm.mtlsUnavailable ? 0.45 : 1.0)
    }

    private func toast(text: String) -> some View {
        Text(text)
            .gsFont(.labelMonoSmall)
            .foregroundColor(C.bg)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(C.signal)
            )
            .padding(.bottom, 86)
            .transition(.opacity)
    }
}

/// Single row in the Admin clients list.
struct ClientRowView: View {

    let client: AdminClient

    @Environment(\.gsColors) private var C

    var body: some View {
        GhostCard(active: client.connected) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Text(client.name)
                        .gsFont(.clientName)
                        .foregroundColor(C.bone)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    statusBadge
                }

                Text(client.tunAddr.isEmpty ? "—" : client.tunAddr)
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Text("↓ \(AdminFormat.bytes(client.bytesRx))")
                        .gsFont(.labelMonoSmall)
                    Text("↑ \(AdminFormat.bytes(client.bytesTx))")
                        .gsFont(.labelMonoSmall)
                    if let days = daysLeft {
                        Text("· \(days)d".uppercased())
                            .gsFont(.labelMonoSmall)
                    }
                    Spacer(minLength: 0)
                    if client.isAdmin { AdminBadge() }
                    if !client.enabled { DisabledBadge() }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(C.textDim)
            }
        }
    }

    private var daysLeft: Int? {
        guard let expiresAt = client.expiresAt else { return nil }
        return Int((expiresAt - Int64(Date().timeIntervalSince1970)) / 86_400)
    }

    private var statusBadge: some View {
        let status = clientStatus
        return Text(status.text.uppercased())
            .gsFont(.labelMonoSmall)
            .foregroundColor(status.color)
    }

    private var clientStatus: (text: String, color: Color) {
        if !client.enabled {
            return ("○ \(L("admin.tag.off"))", C.textFaint)
        }
        if client.connected {
            return ("◉ \(L("admin.tag.live"))", C.signal)
        }
        if let daysLeft, daysLeft < 7 {
            return ("! \(String(format: L("admin.tag.exp.days.left"), max(0, daysLeft)))", C.warn)
        }
        let hours = (client.lastSeenSecs ?? 0) / 3_600
        return ("◌ \(L("admin.tag.idle")) · \(hours)h", C.textDim)
    }
}

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

enum AdminFormat {
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
        let sec = s % 60
        if d > 0 { return "\(d)d" }
        if h > 0 { return "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(sec)s"
    }

    static func subscriptionShort(_ expiresAt: Int64?) -> String {
        guard let exp = expiresAt else { return "∞" }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return "EXPIRED" }
        let days = Int(delta / 86_400)
        if days >= 2 { return "exp \(days)d" }
        let hours = Int(delta / 3_600)
        return "exp \(hours)h"
    }

    static func subscriptionColor(_ expiresAt: Int64?, C: GsColorSet) -> Color {
        guard let exp = expiresAt else { return C.textDim }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return C.danger }
        if delta < 3 * 86_400 { return C.danger }
        if delta < 7 * 86_400 { return C.warn }
        return C.textDim
    }

    static func absoluteDate(_ unix: Int64) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        df.timeZone = TimeZone(secondsFromGMT: 0)
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    static func subscriptionLong(_ expiresAt: Int64?) -> String {
        guard let exp = expiresAt else { return L("admin.subscription.perpetual") }
        let delta = exp - Int64(Date().timeIntervalSince1970)
        if delta <= 0 { return L("admin.subscription.expired") }
        let days = Int(delta / 86_400)
        let hours = Int((delta % 86_400) / 3_600)
        if days >= 1 { return "\(days)d \(hours)h" }
        return "\(hours)h"
    }

    static func lastSeen(_ secs: Int64?) -> String {
        guard let s = secs else { return "—" }
        if s < 60 { return "\(s)s" }
        if s < 3_600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3_600)h" }
        return "\(s / 86_400)d"
    }
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

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
