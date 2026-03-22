import SwiftUI
import AppKit

struct ProfilesTab: View {
    @EnvironmentObject var profileStore: ProfileStore
    @State private var showAdd = false
    @State private var deletingId: String?

    var body: some View {
        VStack(spacing: 0) {
            if profileStore.profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(profileStore.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isActive: profileStore.activeProfileId == profile.id,
                            onSelect: { profileStore.setActive(id: profile.id) },
                            onDelete: { deletingId = profile.id }
                        )
                    }
                }
                .listStyle(.plain)
            }

            Divider()
            HStack {
                Spacer()
                Button { showAdd = true } label: {
                    Label("Добавить", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .padding(10)
            }
        }
        .sheet(isPresented: $showAdd) {
            AddProfileView(isPresented: $showAdd)
                .environmentObject(profileStore)
        }
        .alert("Удалить профиль?", isPresented: Binding(
            get: { deletingId != nil },
            set: { if !$0 { deletingId = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let id = deletingId { profileStore.deleteProfile(id: id) }
                deletingId = nil
            }
            Button("Отмена", role: .cancel) { deletingId = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Нет профилей")
                .font(.headline)
            Text("Добавьте строку подключения\nполученную от администратора")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Добавить подключение") { showAdd = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ProfileRow: View {
    let profile: VpnProfile
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                Text(profile.serverAddr)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if profile.adminUrl != nil {
                    Label("Admin Panel", systemImage: "gearshape.2")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

struct AddProfileView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var profileStore: ProfileStore

    @State private var name = ""
    @State private var connString = ""
    @State private var parsed: ParsedConnString?
    @State private var parseError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Новый профиль")
                    .font(.headline)
                Spacer()
                Button("Отмена") { isPresented = false }
                    .buttonStyle(.plain)
            }
            .padding()
            Divider()

            Form {
                Section {
                    TextField("Название (например, Работа)", text: $name)
                }

                Section("Строка подключения") {
                    TextEditor(text: $connString)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 80)
                        .onChange(of: connString) { _, v in validate(v) }

                    Button("Вставить из буфера") {
                        connString = NSPasteboard.general
                            .string(forType: .string)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                }

                if let e = parseError {
                    Section {
                        Label(e, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let p = parsed {
                    Section("Проверено") {
                        Label("Сервер: \(p.addr)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("TUN: \(p.tun)", systemImage: "network")
                        if p.adminUrl != nil {
                            Label("Admin Panel встроен", systemImage: "shield.checkerboard")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.caption)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Добавить") { addProfile() }
                    .buttonStyle(.borderedProminent)
                    .disabled(parsed == nil)
                    .padding()
            }
        }
        .frame(width: 440, height: 480)
    }

    private func validate(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { parsed = nil; parseError = nil; return }
        do {
            parsed = try ConnStringParser.parse(t)
            parseError = nil
        } catch {
            parsed = nil
            parseError = error.localizedDescription
        }
    }

    private func addProfile() {
        guard let p = parsed else { return }
        let t = connString.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = name.isEmpty ? "Подключение (\(p.addr))" : name
        profileStore.addProfile(VpnProfile(name: n, connString: t, adminUrl: p.adminUrl, adminToken: p.adminToken))
        isPresented = false
    }
}
