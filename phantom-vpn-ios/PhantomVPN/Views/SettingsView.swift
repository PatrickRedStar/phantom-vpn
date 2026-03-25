import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var preferences: PreferencesStore

    @State private var showAddSheet = false
    @State private var showProfileDetails: VpnProfile?
    @State private var importText = ""
    @State private var importName = ""
    @State private var importError: String?
    @State private var showRoutesSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("Подключения") {
                    ForEach(profileStore.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isActive: profile.id == profileStore.activeProfileId,
                            onSetActive: { profileStore.setActive(id: profile.id) },
                            onOpen: { showProfileDetails = profile }
                        )
                    }

                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Добавить подключение", systemImage: "plus.circle")
                    }
                }

                Section("DNS") {
                    ForEach(preferences.dnsServers.indices, id: \.self) { idx in
                        TextField("DNS \(idx + 1)", text: Binding(
                            get: { preferences.dnsServers[idx] },
                            set: { preferences.dnsServers[idx] = $0 }
                        ))
                    }
                    Button("Добавить DNS") {
                        preferences.dnsServers.append("")
                    }
                }

                Section("Маршрутизация") {
                    Toggle("Раздельная маршрутизация", isOn: $preferences.splitRouting)
                    Button("Открыть настройки маршрутизации") {
                        showRoutesSheet = true
                    }
                    .buttonStyle(.bordered)

                    Text("Android-режим: IPv4 + авто-укрупнение до /18")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Приложения") {
                    Text("Per-app VPN недоступен на iOS в текущей схеме Packet Tunnel.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("О приложении") {
                    Text("GhostStream iOS")
                    Text("Debug report можно расширить после интеграции crash/export пайплайна.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .sheet(isPresented: $showAddSheet) {
                addProfileSheet
            }
            .sheet(item: $showProfileDetails) { profile in
                ProfileDetailsSheet(profile: profile)
                    .environmentObject(profileStore)
            }
            .sheet(isPresented: $showRoutesSheet) {
                RoutingSettingsSheet()
                    .environmentObject(preferences)
            }
        }
    }

    private var addProfileSheet: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $importName)
                TextEditor(text: $importText)
                    .frame(minHeight: 120)
            }
            .navigationTitle("Импорт профиля")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { showAddSheet = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Добавить") {
                        do {
                            try profileStore.importConnString(name: importName, connString: importText)
                            showAddSheet = false
                            importName = ""
                            importText = ""
                            importError = nil
                        } catch {
                            importError = error.localizedDescription
                        }
                    }
                }
            }
            .alert("Ошибка импорта", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }
}

private struct ProfileRow: View {
    let profile: VpnProfile
    let isActive: Bool
    let onSetActive: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentPurple : .secondary)
                    .onTapGesture(perform: onSetActive)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(profile.name)
                            .font(.body)
                        if profile.adminUrl != nil && profile.adminToken != nil {
                            Text("ADMIN")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentPurple.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        if isActive {
                            Text("активно")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(profile.serverAddr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("— ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileDetailsSheet: View {
    @EnvironmentObject var profileStore: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State var profile: VpnProfile

    var body: some View {
        NavigationStack {
            Form {
                Section("Параметры") {
                    TextField("Имя", text: $profile.name)
                    Text("Сервер: \(profile.serverAddr)")
                    Text("SNI: \(profile.serverName)")
                }
                Section("Действия") {
                    Button("Сделать активным") {
                        profileStore.setActive(id: profile.id)
                    }
                    Button("Сохранить") {
                        profileStore.updateProfile(profile)
                        dismiss()
                    }
                    Button("Удалить", role: .destructive) {
                        profileStore.deleteProfile(id: profile.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Профиль")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

private struct RoutingSettingsSheet: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @Environment(\.dismiss) private var dismiss
    @State private var downloading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Страны") {
                    ForEach(RoutingRulesManager.allCountryCodes, id: \.self) { code in
                        Toggle(code.uppercased(), isOn: Binding(
                            get: { preferences.directCountries.contains(code) },
                            set: { onToggleCountry(code, enabled: $0) }
                        ))
                    }
                }
                Section {
                    Button(downloading ? "Загрузка..." : "Скачать выбранные") {
                        Task {
                            downloading = true
                            do {
                                try await RoutingRulesManager.shared.downloadAllSelected(codes: preferences.directCountries)
                            } catch {
                                self.error = error.localizedDescription
                            }
                            downloading = false
                        }
                    }
                    .disabled(downloading || preferences.directCountries.isEmpty)
                }
            }
            .navigationTitle("Маршруты")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .alert("Ошибка", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func onToggleCountry(_ code: String, enabled: Bool) {
        if enabled {
            if !preferences.directCountries.contains(code) {
                preferences.directCountries.append(code)
            }
        } else {
            preferences.directCountries.removeAll { $0 == code }
        }
    }
}
