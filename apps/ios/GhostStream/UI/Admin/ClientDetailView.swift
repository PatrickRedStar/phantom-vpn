//
//  ClientDetailView.swift
//  GhostStream
//
//  Per-client admin detail — header, toggles, stats chart, subscription
//  controls, destination logs, and destructive actions.
//

import PhantomUI
import SwiftUI
#if canImport(Charts)
import Charts
#endif
import UIKit

// MARK: - ClientDetailView

/// Per-client admin detail view. Pushed from `AdminView` via NavigationLink.
public struct ClientDetailView: View {

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss

    @State private var vm: ClientDetailViewModel

    @State private var showDeleteConfirm = false
    @State private var showSetDaysSheet = false
    @State private var customDaysText = "30"
    @State private var toastMessage: String?
    @State private var toastTask: Task<Void, Never>?

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
        ZStack {
            C.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    togglesCard
                    statsCard
                    subscriptionCard
                    trafficChartCard
                    logsCard
                    connStringButton
                    deleteButton
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .refreshable {
                await vm.refresh()
            }

            if let msg = toastMessage {
                VStack {
                    Spacer()
                    Text(msg)
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
        .navigationTitle(vm.client.name)
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
        .confirmationDialog("DELETE CLIENT?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("DELETE", role: .destructive) {
                Task {
                    await vm.delete()
                    if vm.error == nil { dismiss() }
                }
            }
            Button("CANCEL", role: .cancel) {}
        } message: {
            Text("Клиент «\(vm.client.name)» будет удалён вместе с сертификатами. Действие необратимо.")
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
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        GhostCard {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(vm.client.connected ? C.signal : C.textFaint)
                    .frame(width: 10, height: 10)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(vm.client.name)
                            .gsFont(.profileName)
                            .foregroundColor(C.bone)
                        if vm.client.isAdmin {
                            AdminBadge()
                        }
                    }
                    Text(vm.client.tunAddr)
                        .gsFont(.valueMono)
                        .foregroundColor(C.textDim)
                    Text(vm.client.fingerprint)
                        .gsFont(.host)
                        .foregroundColor(C.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Toggles

    private var togglesCard: some View {
        GhostCard {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Text("ENABLED")
                        .gsFont(.labelMono)
                        .foregroundColor(C.textDim)
                    Spacer()
                    GhostToggle(isOn: Binding(
                        get: { vm.client.enabled },
                        set: { newValue in Task { await vm.setEnabled(newValue) } }
                    ), onLabel: "ENABLED")
                }
                .opacity(vm.mutating ? 0.5 : 1)
                .allowsHitTesting(!vm.mutating)

                Divider().background(C.hair)

                HStack(spacing: 12) {
                    Text("IS ADMIN")
                        .gsFont(.labelMono)
                        .foregroundColor(C.textDim)
                    Spacer()
                    GhostToggle(isOn: Binding(
                        get: { vm.client.isAdmin },
                        set: { newValue in Task { await vm.setAdmin(newValue) } }
                    ), onLabel: "IS ADMIN")
                }
                .opacity(vm.mutating ? 0.5 : 1)
                .allowsHitTesting(!vm.mutating)
            }
        }
    }

    // MARK: - Stats

    private var statsCard: some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("STATS")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textDim)
                kvRow("RX TOTAL",  AdminFormat.bytes(vm.client.bytesRx))
                kvRow("TX TOTAL",  AdminFormat.bytes(vm.client.bytesTx))
                kvRow("LAST SEEN", AdminFormat.lastSeen(vm.client.lastSeenSecs))
                kvRow("CREATED",   vm.client.createdAt)
            }
        }
    }

    // MARK: - Subscription

    private var subscriptionCard: some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("SUBSCRIPTION")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textDim)

                if let exp = vm.client.expiresAt {
                    kvRow("EXPIRES",  AdminFormat.absoluteDate(exp))
                    kvRow("REMAINING", AdminFormat.subscriptionLong(exp))
                } else {
                    kvRow("EXPIRES", "Бессрочно")
                }

                // Action buttons — wrap so they flow on narrow screens.
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        subscriptionActionButton(title: "+30 ДНЕЙ", tint: C.signal) {
                            Task { await vm.subscription(action: "extend", days: 30) }
                        }
                        subscriptionActionButton(title: "+90 ДНЕЙ", tint: C.signal) {
                            Task { await vm.subscription(action: "extend", days: 90) }
                        }
                    }
                    HStack(spacing: 8) {
                        subscriptionActionButton(title: "ВЫБРАТЬ…", tint: C.bone) {
                            customDaysText = "30"
                            showSetDaysSheet = true
                        }
                        subscriptionActionButton(title: "БЕССРОЧНО", tint: C.bone) {
                            Task { await vm.subscription(action: "cancel", days: nil) }
                        }
                    }
                    subscriptionActionButton(
                        title: "REVOKE NOW",
                        tint: C.bg,
                        bg: C.danger,
                        fullWidth: true
                    ) {
                        Task { await vm.subscription(action: "revoke", days: nil) }
                    }
                }
            }
        }
    }

    private func subscriptionActionButton(
        title: String,
        tint: Color,
        bg: Color? = nil,
        fullWidth: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .gsFont(.fabText)
                .foregroundColor(tint)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(bg ?? C.bgElev2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(bg == nil ? C.hairBold : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(vm.mutating)
    }

    // MARK: - Traffic chart

    @ViewBuilder
    private var trafficChartCard: some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("TRAFFIC")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textDim)

                if vm.stats.isEmpty {
                    Text(vm.loading ? "LOADING…" : "NO DATA")
                        .gsFont(.labelMonoSmall)
                        .foregroundColor(C.textFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    trafficChart
                        .frame(height: 120)
                }

                if let last = vm.stats.last {
                    HStack {
                        Text("↓ \(AdminFormat.bytes(last.bytesRx))")
                            .gsFont(.valueMono)
                            .foregroundColor(C.signal)
                        Spacer()
                        Text("↑ \(AdminFormat.bytes(last.bytesTx))")
                            .gsFont(.valueMono)
                            .foregroundColor(C.warn)
                    }
                }
            }
        }
    }

    /// Line chart via Swift Charts (iOS 16+). Falls back to a simple text
    /// summary on older SDKs.
    @ViewBuilder
    private var trafficChart: some View {
        #if canImport(Charts)
        if #available(iOS 16.0, *) {
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
        } else {
            Text("Требуется iOS 16+")
                .gsFont(.labelMonoSmall)
                .foregroundColor(C.textFaint)
        }
        #else
        Text("Charts framework unavailable")
            .gsFont(.labelMonoSmall)
            .foregroundColor(C.textFaint)
        #endif
    }

    // MARK: - Logs

    private var logsCard: some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("DESTINATIONS (\(vm.logs.count))")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textDim)

                if vm.logs.isEmpty {
                    Text(vm.loading ? "LOADING…" : "NO DATA")
                        .gsFont(.labelMonoSmall)
                        .foregroundColor(C.textFaint)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    let ordered = Array(vm.logs.reversed())
                    VStack(spacing: 4) {
                        ForEach(ordered.indices, id: \.self) { i in
                            logRow(ordered[i])
                        }
                    }
                }
            }
        }
    }

    private func logRow(_ e: ClientLog) -> some View {
        HStack(spacing: 8) {
            Text(shortTime(e.ts))
                .gsFont(.logTs)
                .foregroundColor(C.textFaint)
                .frame(width: 52, alignment: .leading)
            Text(e.dst)
                .gsFont(.host)
                .foregroundColor(C.bone)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(":\(e.port)")
                .gsFont(.logTs)
                .foregroundColor(C.textDim)
            Text(e.proto.uppercased())
                .gsFont(.labelMonoTiny)
                .foregroundColor(C.textDim)
            Text(AdminFormat.bytes(e.bytes))
                .gsFont(.logTs)
                .foregroundColor(C.textFaint)
        }
        .padding(.vertical, 2)
    }

    private func shortTime(_ unix: Int64) -> String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    // MARK: - Conn string & delete

    private var connStringButton: some View {
        Button {
            Task {
                if let s = await vm.getConnString() {
                    UIPasteboard.general.string = s
                    showToast("Conn-string скопирован")
                }
            }
        } label: {
            Text("КОПИРОВАТЬ CONN-STRING")
                .gsFont(.fabText)
                .foregroundColor(C.bone)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(C.hairBold, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(vm.mutating)
    }

    private var deleteButton: some View {
        Button {
            showDeleteConfirm = true
        } label: {
            Text("DELETE CLIENT")
                .gsFont(.fabText)
                .foregroundColor(C.bg)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(C.danger)
                )
        }
        .buttonStyle(.plain)
        .disabled(vm.mutating)
    }

    // MARK: - Helpers

    private func kvRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .gsFont(.labelMonoSmall)
                .foregroundColor(C.textDim)
            Spacer()
            Text(value)
                .gsFont(.valueMono)
                .foregroundColor(C.bone)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func showToast(_ msg: String) {
        toastTask?.cancel()
        toastMessage = msg
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { toastMessage = nil }
            }
        }
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
                    Text("Подписка будет установлена с «сейчас + N дней», независимо от текущего срока.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("SET SUBSCRIPTION")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("CANCEL", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK", action: onSave)
                        .disabled(Int(daysText).map { $0 <= 0 } ?? true)
                }
            }
        }
    }
}

// MARK: - Previews

#Preview("ClientDetailView") {
    NavigationStack {
        ClientDetailView(viewModel: AdminPreviewData.detailVM())
    }
    .gsTheme(override: .dark)
}
