import SwiftUI

struct AdminView: View {
    @EnvironmentObject private var adminManager: AdminManager
    @State private var searchQuery = ""
    @State private var showCreate = false
    @State private var deleteConfirm: String?
    @State private var subClient: AdminClientInfo?

    private var filtered: [AdminClientInfo] {
        adminManager.clients.filter { searchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск", text: $searchQuery)
                Spacer()
                if adminManager.loading {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Button {
                        adminManager.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                Button {
                    showCreate = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
            .padding(12)

            if let err = adminManager.error {
                Text(err)
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
            }

            if let s = adminManager.status {
                HStack(spacing: 12) {
                    Label(s.serverAddr, systemImage: "server.rack")
                    Label("\(s.sessionsActive) онлайн", systemImage: "person.fill")
                    Label(formatUptime(s.uptimeSecs), systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
            }

            List(filtered) { client in
                HStack {
                    Circle()
                        .fill(client.connected ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading) {
                        Text(client.name).font(.subheadline)
                        Text(client.tunAddr).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        subClient = client
                    } label: { Image(systemName: "calendar.badge.clock") }
                    Button {
                        adminManager.setEnabled(name: client.name, enabled: !client.enabled)
                    } label: {
                        Image(systemName: client.enabled ? "toggle.on" : "toggle.off")
                    }
                    Button {
                        adminManager.getConnString(name: client.name)
                    } label: {
                        Image(systemName: "qrcode")
                    }
                    Button(role: .destructive) {
                        deleteConfirm = client.name
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .navigationTitle("Админ")
        .onAppear {
            adminManager.refresh()
        }
        .alert("Удалить клиента?", isPresented: Binding(get: { deleteConfirm != nil }, set: { if !$0 { deleteConfirm = nil } })) {
            Button("Удалить", role: .destructive) {
                if let name = deleteConfirm {
                    adminManager.deleteClient(name: name)
                }
            }
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $showCreate) {
            CreateClientSheet(isPresented: $showCreate)
                .environmentObject(adminManager)
        }
        .sheet(item: $subClient) { client in
            SubscriptionSheet(client: client, isPresented: Binding(
                get: { subClient != nil },
                set: { if !$0 { subClient = nil } }
            ))
            .environmentObject(adminManager)
        }
        .sheet(isPresented: Binding(get: { adminManager.newConnString != nil }, set: { if !$0 { adminManager.clearNewConnString() } })) {
            ConnStringResultSheet(connString: adminManager.newConnString ?? "")
        }
    }
}

private struct CreateClientSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var adminManager: AdminManager
    @State private var name = ""
    @State private var daysText = "30"

    var body: some View {
        NavigationStack {
            Form {
                TextField("Имя", text: $name)
                TextField("Дней (пусто = бессрочно)", text: $daysText)
                    .keyboardType(.numberPad)
            }
            .navigationTitle("Новый клиент")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { isPresented = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Создать") {
                        adminManager.createClient(
                            name: name.trimmingCharacters(in: .whitespaces),
                            expiresDays: daysText.isEmpty ? nil : Int(daysText)
                        )
                        isPresented = false
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct SubscriptionSheet: View {
    let client: AdminClientInfo
    @Binding var isPresented: Bool
    @EnvironmentObject var adminManager: AdminManager

    var body: some View {
        NavigationStack {
            List {
                Button("Продлить +30") { action("extend", 30) }
                Button("Продлить +90") { action("extend", 90) }
                Button("Установить 30") { action("set", 30) }
                Button("Отменить лимит") { action("cancel", nil) }
                Button("Отозвать", role: .destructive) { action("revoke", nil) }
            }
            .navigationTitle("Подписка \(client.name)")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { isPresented = false }
                }
            }
        }
    }

    private func action(_ op: String, _ days: Int?) {
        adminManager.manageSubscription(name: client.name, action: op, days: days)
        isPresented = false
    }
}

private struct ConnStringResultSheet: View {
    let connString: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("Строка подключения").font(.headline)
            ScrollView {
                Text(connString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Button("Скопировать") {
                UIPasteboard.general.string = connString
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

private func formatUptime(_ secs: Int64) -> String {
    let h = secs / 3600
    let m = (secs % 3600) / 60
    return h > 0 ? "\(h)ч \(m)м" : "\(m)м"
}
