import SwiftUI

struct AdminPanelView: View {
    @EnvironmentObject var adminManager: AdminManager
    @State private var searchQuery = ""
    @State private var showCreate = false
    @State private var deleteConfirm: String?
    @State private var subClient: AdminClientInfo?

    var filtered: [AdminClientInfo] {
        adminManager.clients.filter {
            searchQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск", text: $searchQuery)
                    .textFieldStyle(.plain)
                Spacer()
                if adminManager.loading {
                    ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                } else {
                    Button { adminManager.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
                Button { showCreate = true } label: {
                    Image(systemName: "person.badge.plus")
                }
                .buttonStyle(.plain)
                .help("Создать клиента")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Error
            if let err = adminManager.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                    Spacer()
                    Button { adminManager.error = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.orange.opacity(0.1))
            }

            // Status card
            if let s = adminManager.status {
                HStack(spacing: 16) {
                    Label(s.serverAddr, systemImage: "server.rack")
                    Divider().frame(height: 16)
                    Label("\(s.sessionsActive) онлайн", systemImage: "person.fill")
                    Divider().frame(height: 16)
                    Label(formatUptime(s.uptimeSecs), systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.quaternary)
            }

            Divider()

            // Client list
            List(filtered) { client in
                AdminClientRow(
                    client: client,
                    onToggle: { adminManager.setEnabled(name: client.name, enabled: !client.enabled) },
                    onDelete: { deleteConfirm = client.name },
                    onCopyConnString: { adminManager.getConnString(name: client.name) },
                    onSubscription: { subClient = client }
                )
            }
            .listStyle(.plain)
        }
        .onAppear { adminManager.refresh() }
        .sheet(isPresented: $showCreate) {
            CreateClientView(isPresented: $showCreate)
                .environmentObject(adminManager)
        }
        .sheet(item: $subClient) { client in
            SubscriptionView(client: client, isPresented: Binding(
                get: { subClient != nil },
                set: { if !$0 { subClient = nil } }
            ))
            .environmentObject(adminManager)
        }
        .alert("Удалить клиента?", isPresented: Binding(
            get: { deleteConfirm != nil },
            set: { if !$0 { deleteConfirm = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let n = deleteConfirm { adminManager.deleteClient(name: n) }
                deleteConfirm = nil
            }
            Button("Отмена", role: .cancel) { deleteConfirm = nil }
        }
        // Conn string result
        .sheet(isPresented: Binding(get: { adminManager.newConnString != nil }, set: { if !$0 { adminManager.clearNewConnString() } })) {
            ConnStringResultView(connString: adminManager.newConnString ?? "")
        }
    }
}

private struct AdminClientRow: View {
    let client: AdminClientInfo
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onCopyConnString: () -> Void
    let onSubscription: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Online dot
            Circle()
                .fill(client.connected ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(client.name)
                        .font(.subheadline)
                        .fontWeight(client.connected ? .semibold : .regular)
                    if let label = client.subLabel {
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(client.subColor.opacity(0.18))
                            .foregroundStyle(client.subColor)
                            .cornerRadius(4)
                    }
                    if !client.enabled {
                        Text("Откл.")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.red.opacity(0.15))
                            .foregroundStyle(.red)
                            .cornerRadius(4)
                    }
                }
                if client.connected {
                    Text("↓ \(formatBytes(client.bytesRx))  ↑ \(formatBytes(client.bytesTx))  · \(client.lastSeenSecs)s ago")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(client.tunAddr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Actions
            Button(action: onSubscription) {
                Image(systemName: "calendar.badge.clock")
            }
            .buttonStyle(.plain)
            .help("Подписка")

            Button(action: onToggle) {
                Image(systemName: client.enabled ? "toggle.on" : "toggle.off")
                    .foregroundStyle(client.enabled ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(client.enabled ? "Отключить" : "Включить")

            Button(action: onCopyConnString) {
                Image(systemName: "qrcode")
            }
            .buttonStyle(.plain)
            .help("Строка подключения")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Удалить")
        }
        .padding(.vertical, 4)
    }
}

private struct CreateClientView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var adminManager: AdminManager
    @State private var name = ""
    @State private var daysText = "30"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Новый клиент")
                    .font(.headline)
                Spacer()
                Button("Отмена") { isPresented = false }
                    .buttonStyle(.plain)
            }
            .padding()
            Divider()

            Form {
                TextField("Имя (a-z, 0-9, дефис)", text: $name)
                TextField("Дней подписки (пусто = бессрочно)", text: $daysText)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Создать") {
                    adminManager.createClient(name: name.trimmingCharacters(in: .whitespaces), expiresDays: daysText.isEmpty ? nil : Int(daysText))
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding()
            }
        }
        .frame(width: 360, height: 260)
    }
}

private struct ConnStringResultView: View {
    let connString: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Строка подключения")
                .font(.headline)
            ScrollView {
                Text(connString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary)
                    .cornerRadius(6)
            }
            .frame(maxHeight: 120)
            HStack {
                Button("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connString, forType: .string)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                Button("Закрыть") { dismiss() }
            }
        }
        .padding()
        .frame(width: 400, height: 280)
    }
}

// MARK: - Helpers

func formatUptime(_ secs: Int64) -> String {
    let h = secs / 3600; let m = (secs % 3600) / 60
    return h > 0 ? "\(h)ч \(m)м" : "\(m)м"
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
}
