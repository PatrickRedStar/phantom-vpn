//
//  AdminView.swift
//  GhostStream
//
//  «Админка»: online / clients / uptime tiles, client rows, «Новый клиент»
//  as the floating primary glass button.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Top-level Admin screen.
public struct AdminView: View {

    @Environment(\.gsColors) private var C
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var vm: AdminViewModel
    @State private var showCreateSheet = false

    public init(profile: VpnProfile) {
        _vm = State(initialValue: AdminViewModel(profile: profile))
    }

    init(viewModel: AdminViewModel) {
        _vm = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if vm.mtlsUnavailable {
                    banner(title: L("admin.mtls.unavailable"), detail: vm.error ?? L("admin.ed25519.error"))
                } else if let err = vm.error, vm.status == nil {
                    banner(title: L("admin.error"), detail: err)
                }

                statTiles
                SectionLabel(text: L("admin.clients"))
                clientsCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .background(C.bg.ignoresSafeArea())
        .scrollIndicators(.hidden)
        .refreshable {
            await vm.refresh()
        }
        .safeAreaInset(edge: .bottom) {
            createButton
        }
        .navigationTitle(L("admin.nav.title"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await vm.refresh() }
                } label: {
                    Label(L("admin.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(vm.loading)
            }
        }
        .task {
            await vm.refresh()
        }
        .sheet(isPresented: $showCreateSheet) {
            CreateClientSheet(viewModel: vm)
                .environment(\.gsColors, C)
        }
    }

    private func banner(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.custom(GsFontName.spaceGroteskBold, size: 15))
                .foregroundStyle(C.danger)
            Text(detail)
                .font(.custom(GsFontName.jetBrainsMono, size: 11))
                .foregroundStyle(C.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(C.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(C.danger.opacity(0.35), lineWidth: 1)
        )
    }

    private var statTiles: some View {
        let online = vm.clients.filter(\.connected).count
        // Accessibility sizes: three tiles in a row leave «ОНЛ…» / «2…».
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            tile(L("admin.stat.online"), vm.status == nil ? "—" : "\(online)", color: online > 0 ? C.signal : C.bone)
            tile(L("admin.stat.clients"), vm.status == nil ? "—" : "\(vm.clients.count)")
            tile(L("admin.uptime"), vm.status.map { AdminFormat.duration($0.uptimeSecs) } ?? "—")
        }
    }

    private func tile(_ label: String, _ value: String, color: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .gsFont(.labelMonoTiny)
                .foregroundStyle(C.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(value)
                .font(.custom(GsFontName.spaceGroteskBold, size: 24))
                .foregroundStyle(color ?? C.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .gsCardBackground(C, radius: 20)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var clientsCard: some View {
        if vm.clients.isEmpty && !vm.loading {
            NativeSectionCard {
                Text(L("admin.no.clients"))
                    .font(.custom(GsFontName.jetBrainsMono, size: 12))
                    .foregroundStyle(C.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            }
        } else {
            NativeSectionCard {
                ForEach(Array(vm.clients.enumerated()), id: \.element.id) { idx, client in
                    NavigationLink(destination: ClientDetailView(client: client, adminVM: vm)) {
                        ClientRowView(client: client)
                    }
                    .buttonStyle(.plain)
                    if idx < vm.clients.count - 1 {
                        HairlineDivider()
                    }
                }
            }
        }
    }

    private var createButton: some View {
        GlassPrimaryButton(
            title: L("admin.new.client"),
            systemImage: "plus",
            tint: C.signal
        ) {
            showCreateSheet = true
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .disabled(vm.mtlsUnavailable)
        .opacity(vm.mtlsUnavailable ? 0.45 : 1.0)
        .bottomActionFade(C.bg)
    }
}

/// Single row in the Admin clients list.
struct ClientRowView: View {

    let client: AdminClient

    @Environment(\.gsColors) private var C
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Accessibility sizes: the days badge moves under the name.
        let large = typeSize.isAccessibilitySize
        HStack(spacing: 12) {
            ClientStatusDot(client: client)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(client.name)
                        .font(.custom(GsFontName.spaceGroteskBold, size: 17))
                        .foregroundStyle(C.bone)
                        .lineLimit(1)
                        .minimumScaleFactor(large ? 0.5 : 1)
                    if client.isAdmin { AdminBadge() }
                }
                Text(subtitle)
                    .font(.custom(GsFontName.jetBrainsMono, size: 10))
                    .foregroundStyle(C.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if large { daysBadge }
            }
            Spacer(minLength: 8)
            if !large { daysBadge }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(C.textDim)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var daysBadge: some View {
        if let days = AdminFormat.daysLeft(client.expiresAt), client.enabled, days >= 0 {
            Text(String(format: L("settings.profile.days.format"), Int64(days)).uppercased())
                .gsFont(.labelMonoSmall)
                .foregroundStyle(days < 14 ? C.warn : C.textDim)
        }
    }

    private var subtitle: String {
        if !client.enabled || AdminFormat.daysLeft(client.expiresAt).map({ $0 < 0 }) == true {
            var parts = [L("admin.client.off")]
            if AdminFormat.daysLeft(client.expiresAt).map({ $0 < 0 }) == true {
                parts.append(L("admin.client.expired"))
            }
            return parts.joined(separator: " · ")
        }
        if client.connected {
            let ip = client.tunAddr.split(separator: "/").first.map(String.init) ?? client.tunAddr
            return "\(ip) · ↓ \(AdminFormat.bytes(client.bytesRx)) ↑ \(AdminFormat.bytes(client.bytesTx))"
        }
        guard let secs = client.lastSeenSecs else { return L("admin.client.never") }
        return String(format: L("admin.client.seen.format"), AdminFormat.duration(secs))
    }
}

/// Lime dot (glowing) online, hollow ring offline, red when disabled.
struct ClientStatusDot: View {
    let client: AdminClient
    @Environment(\.gsColors) private var C

    var body: some View {
        Group {
            if !client.enabled {
                Circle().fill(C.danger)
            } else if client.connected {
                Circle().fill(C.signal).shadow(color: C.signal, radius: 4)
            } else {
                Circle().strokeBorder(C.textDim, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
    }
}

struct AdminBadge: View {
    @Environment(\.gsColors) private var C
    var body: some View {
        Text("ADMIN")
            .gsFont(.labelMonoTiny)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(C.bg)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(C.signal, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

enum AdminFormat {
    static func bytes(_ n: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        fmt.countStyle = .binary
        return fmt.string(fromByteCount: n)
    }

    /// «18 ч», «3 д» — one unit, in the app's language.
    static func duration(_ secs: Int64) -> String {
        let fmt = DateComponentsFormatter()
        fmt.unitsStyle = .short
        fmt.maximumUnitCount = 1
        fmt.allowedUnits = [.day, .hour, .minute, .second]
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: AppStrings.isEnglish ? "en" : "ru")
        fmt.calendar = calendar
        return fmt.string(from: TimeInterval(max(0, secs))) ?? "\(secs)s"
    }

    /// Whole days until `expiresAt`; negative once expired, nil = perpetual.
    static func daysLeft(_ expiresAt: Int64?) -> Int? {
        guard let expiresAt else { return nil }
        let delta = expiresAt - Int64(Date().timeIntervalSince1970)
        return delta < 0 ? -1 : Int(delta / 86_400)
    }

    static func shortDate(_ unix: Int64) -> String {
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}

private func L(_ key: String) -> String {
    AppStrings.localized(key)
}

#if DEBUG
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
#endif
