//
//  ClientDetailView.swift
//  GhostStream
//
//  Per-client admin detail — status, link as QR + share + copy, access /
//  admin toggles, subscription chips, traffic chart, destinations. Rare
//  and destructive actions live in the toolbar «…» menu.
//

import PhantomKit
import PhantomUI
import SwiftUI
import Charts

// MARK: - ClientDetailView

/// Per-client admin detail view. Pushed from `AdminView` via NavigationLink.
public struct ClientDetailView: View {

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss

    @State private var vm: ClientDetailViewModel
    @State private var connString: String?

    @State private var showDeleteConfirm = false
    @State private var showSetDaysSheet = false
    @State private var customDaysText = "30"

    /// - Parameters:
    ///   - client: initial row snapshot.
    ///   - adminVM: parent admin VM used for all mutations.
    public init(client: AdminClient, adminVM: AdminViewModel) {
        _vm = State(initialValue: ClientDetailViewModel(client: client, adminVM: adminVM))
    }

    /// Preview-only init with a pre-built VM.
    init(viewModel: ClientDetailViewModel) {
        _vm = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusLine
                if let connString {
                    ConnStringShareCard(connString: connString)
                }
                togglesCard
                SectionLabel(text: subscriptionCaption)
                subscriptionChips
                trafficCard
                destinationsCard
                if let error = vm.error {
                    Text(error)
                        .font(.custom(GsFontName.jetBrainsMono, size: 11))
                        .foregroundStyle(C.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(C.bg.ignoresSafeArea())
        .refreshable {
            await vm.refresh()
        }
        .navigationTitle(vm.client.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        customDaysText = "30"
                        showSetDaysSheet = true
                    } label: {
                        Label(L("admin.subscription.custom"), systemImage: "calendar")
                    }
                    Button(role: .destructive) {
                        Task { await vm.subscription(action: "revoke", days: nil) }
                    } label: {
                        Label(L("admin.subscription.revoke.now"), systemImage: "hand.raised")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(L("admin.client.delete.action"), systemImage: "trash")
                    }
                } label: {
                    Label(L("admin.client.more"), systemImage: "ellipsis")
                }
                .disabled(vm.mutating)
            }
        }
        .confirmationDialog(L("admin.client.delete.title"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L("general.delete"), role: .destructive) {
                Task {
                    await vm.delete()
                    if vm.error == nil { dismiss() }
                }
            }
            Button(L("general.cancel"), role: .cancel) {}
        } message: {
            Text(String(format: L("admin.client.delete.message"), vm.client.name))
        }
        .sheet(isPresented: $showSetDaysSheet) {
            SetSubscriptionDaysSheet(
                daysText: $customDaysText,
                onSave: {
                    guard let n = Int(customDaysText), n > 0 else { return }
                    Task {
                        await vm.subscription(action: "set", days: n)
                        showSetDaysSheet = false
                    }
                },
                onCancel: {
                    showSetDaysSheet = false
                }
            )
            .presentationDetents([.medium])
            .environment(\.gsColors, C)
        }
        .task {
            await vm.refresh()
            connString = await vm.getConnString()
        }
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 8) {
            ClientStatusDot(client: vm.client)
            Text(statusText.uppercased())
                .gsFont(.labelMonoSmall)
                .foregroundStyle(statusColor)
            if vm.client.isAdmin { AdminBadge() }
            Spacer()
            Text(vm.client.tunAddr)
                .font(.custom(GsFontName.jetBrainsMono, size: 11))
                .foregroundStyle(C.textDim)
        }
        .padding(.horizontal, 4)
    }

    private var statusText: String {
        if !vm.client.enabled { return L("admin.client.off") }
        if vm.client.connected { return L("admin.client.online") }
        guard let secs = vm.client.lastSeenSecs else { return L("admin.client.never") }
        return String(format: L("admin.client.seen.format"), AdminFormat.duration(secs))
    }

    private var statusColor: Color {
        if !vm.client.enabled { return C.danger }
        return vm.client.connected ? C.signal : C.textDim
    }

    // MARK: - Toggles

    private var togglesCard: some View {
        NativeSectionCard {
            Toggle(isOn: Binding(
                get: { vm.client.enabled },
                set: { newValue in Task { await vm.setEnabled(newValue) } }
            )) {
                toggleTitle(L("admin.client.access"))
            }
            .padding(.vertical, 12)
            HairlineDivider()
            Toggle(isOn: Binding(
                get: { vm.client.isAdmin },
                set: { newValue in Task { await vm.setAdmin(newValue) } }
            )) {
                toggleTitle(L("admin.client.administrator"))
            }
            .padding(.vertical, 12)
        }
        .tint(C.signal)
        .disabled(vm.mutating)
    }

    private func toggleTitle(_ text: String) -> some View {
        Text(text)
            .font(.custom(GsFontName.jetBrainsMono, size: 13))
            .foregroundStyle(C.bone)
    }

    // MARK: - Subscription

    private var subscriptionCaption: String {
        let tail = vm.client.expiresAt.map {
            String(format: L("admin.subscription.until.format"), AdminFormat.shortDate($0))
        } ?? L("admin.subscription.perpetual")
        return "\(L("native.profile.subscription")) · \(tail)"
    }

    private var subscriptionChips: some View {
        HStack(spacing: 8) {
            chip(L("admin.subscription.chip30")) {
                Task { await vm.subscription(action: "extend", days: 30) }
            }
            chip(L("admin.subscription.chip90")) {
                Task { await vm.subscription(action: "extend", days: 90) }
            }
            chip(L("admin.subscription.perpetual")) {
                Task { await vm.subscription(action: "cancel", days: nil) }
            }
        }
        .disabled(vm.mutating)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .gsFont(.chipText)
                .foregroundStyle(C.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(C.bgElev, in: Capsule())
                .overlay(Capsule().stroke(C.hair, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Traffic chart

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("admin.client.traffic").uppercased())
                    .gsFont(.labelMono)
                    .foregroundStyle(C.textDim)
                Spacer()
                if let last = vm.stats.last {
                    Text("↓ \(AdminFormat.bytes(last.bytesRx))  ↑ \(AdminFormat.bytes(last.bytesTx))")
                        .font(.custom(GsFontName.jetBrainsMono, size: 11))
                        .foregroundStyle(C.signal)
                }
            }
            if vm.stats.isEmpty {
                Text(vm.loading ? L("general.loading") : L("general.no.data"))
                    .font(.custom(GsFontName.jetBrainsMono, size: 11))
                    .foregroundStyle(C.textFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                Chart {
                    ForEach(vm.stats.indices, id: \.self) { idx in
                        let s = vm.stats[idx]
                        LineMark(
                            x: .value("t", s.ts),
                            y: .value("RX", s.bytesRx),
                            series: .value("series", "RX")
                        )
                        .foregroundStyle(C.signal)
                        LineMark(
                            x: .value("t", s.ts),
                            y: .value("TX", s.bytesTx),
                            series: .value("series", "TX")
                        )
                        .foregroundStyle(C.warn)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(C.hair)
                    }
                }
                .frame(height: 96)
            }
        }
        .padding(18)
        .gsCardBackground(C)
    }

    // MARK: - Destinations

    @ViewBuilder
    private var destinationsCard: some View {
        if !vm.logs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: L("admin.client.destinations.count"), vm.logs.count).uppercased())
                    .gsFont(.labelMono)
                    .foregroundStyle(C.textDim)
                let ordered = Array(vm.logs.reversed())
                ForEach(ordered.indices, id: \.self) { i in
                    logRow(ordered[i])
                }
            }
            .padding(18)
            .gsCardBackground(C)
        }
    }

    private func logRow(_ e: ClientLog) -> some View {
        HStack(spacing: 8) {
            Text(shortTime(e.ts))
                .foregroundColor(C.textFaint)
            Text(e.dst)
                .foregroundColor(C.bone)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(":\(e.port) \(e.proto.uppercased())")
                .foregroundColor(C.textDim)
            Text(AdminFormat.bytes(e.bytes))
                .foregroundColor(C.textFaint)
        }
        .font(.custom(GsFontName.jetBrainsMono, size: 10))
    }

    private func shortTime(_ unix: Int64) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}

private struct SetSubscriptionDaysSheet: View {
    @Binding var daysText: String
    let onSave: () -> Void
    let onCancel: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("30", text: $daysText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text(L("admin.subscription.set.footer"))
                }
            }
            .scrollContentBackground(.hidden)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("admin.subscription.set.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("general.cancel").uppercased(), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("general.ok"), action: onSave)
                        .disabled(Int(daysText).map { $0 <= 0 } ?? true)
                }
            }
        }
    }
}

private func L(_ key: String) -> String {
    AppStrings.localized(key)
}

// MARK: - Previews

#if DEBUG
#Preview("ClientDetailView") {
    NavigationStack {
        ClientDetailView(viewModel: AdminPreviewData.detailVM())
    }
    .gsTheme(override: .dark)
}
#endif
