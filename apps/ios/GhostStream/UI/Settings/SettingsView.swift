//
//  SettingsView.swift
//  GhostStream
//
//  Settings screen — profile list, DNS / split-routing, theme & language,
//  and about info. Uses `ScrollView`+`GhostCard` rather than `Form` because
//  `Form` bakes in iOS system chrome that fights the Ghoststream palette.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Root SwiftUI view for the Settings tab.
public struct SettingsView: View {

    @State private var model = SettingsViewModel()
    @State private var showAddSheet: Bool = false
    @State private var pasteDraft: String = ""
    @State private var showPasteSheet: Bool = false
    @State private var showQRSheet: Bool = false
    @State private var editorProfileId: String? = nil
    @State private var deleteProfileId: String? = nil
    @State private var importErrorText: String? = nil
    @State private var adminProfile: VpnProfile? = nil

    // DNS editor
    @State private var dnsDraft: [String] = []
    @State private var newDnsEntry: String = ""

    // Split routing
    @State private var splitOn: Bool = false

    // Theme
    @State private var themeSelection: ThemeOverride = .system
    // Language
    @State private var languageSelection: String = "system" // "system" | "en" | "ru"

    @Environment(\.gsColors) private var C

    public init() {}

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    profilesSection
                    if let active = model.activeProfile {
                        activeProfileSection(active: active)
                    }
                    appearanceSection
                    platformNoteSection
                    aboutSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
            }
            .background(C.bg.ignoresSafeArea())
            .scrollIndicators(.hidden)
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { adminProfile != nil },
                set: { if !$0 { adminProfile = nil } }
            )) {
                if let p = adminProfile {
                    AdminView(profile: p)
                }
            }
            .task {
                hydrate()
                await model.refreshPings()
            }
            .refreshable {
                await model.refreshPings()
            }
        }
        // Add profile action sheet
        .confirmationDialog("Добавить профиль",
                            isPresented: $showAddSheet,
                            titleVisibility: .visible) {
            Button("Вставить строку подключения") { showPasteSheet = true }
            Button("Отсканировать QR")            { showQRSheet = true }
            Button("Отмена", role: .cancel) {}
        }
        // Paste sheet
        .sheet(isPresented: $showPasteSheet) {
            PasteConnStringSheet(
                text: $pasteDraft,
                onSubmit: { raw in
                    importConnString(raw)
                    showPasteSheet = false
                },
                onCancel: { showPasteSheet = false }
            )
            .environment(\.gsColors, C)
        }
        // QR scan
        .sheet(isPresented: $showQRSheet) {
            QRScannerView(
                onScan: { payload in
                    importConnString(payload)
                    showQRSheet = false
                },
                onCancel: { showQRSheet = false }
            )
            .ignoresSafeArea()
        }
        // Profile editor
        .sheet(isPresented: Binding(
            get: { editorProfileId != nil },
            set: { if !$0 { editorProfileId = nil } }
        )) {
            if let id = editorProfileId {
                ProfileEditorView(model: model, profileId: id, onClose: { editorProfileId = nil })
                    .environment(\.gsColors, C)
            }
        }
        // Import error alert
        .alert("Ошибка импорта",
               isPresented: Binding(
                get: { importErrorText != nil },
                set: { if !$0 { importErrorText = nil } }
               )) {
            Button("OK", role: .cancel) { importErrorText = nil }
        } message: {
            Text(importErrorText ?? "")
        }
        // Long-press delete confirmation
        .alert("Удалить профиль?",
               isPresented: Binding(
                get: { deleteProfileId != nil },
                set: { if !$0 { deleteProfileId = nil } }
               )) {
            Button("Удалить", role: .destructive) {
                if let id = deleteProfileId { model.deleteProfile(id: id) }
                deleteProfileId = nil
            }
            Button("Отмена", role: .cancel) { deleteProfileId = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("SETTINGS")
                .gsFont(.brand)
                .foregroundColor(C.bone)
            Spacer()
            Text(buildMeta)
                .gsFont(.hdrMeta)
                .foregroundColor(C.textFaint)
        }
    }

    private var buildMeta: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return "V\(version) · \(build)"
    }

    // MARK: - Profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                "ПРОФИЛИ",
                right: String(format: "· %02d", model.profiles.count)
            )

            ForEach(model.profiles, id: \.id) { profile in
                ProfileCard(
                    profile: profile,
                    isActive: profile.id == model.activeId,
                    pingMs: model.pingResults[profile.id],
                    isPinging: model.pinging.contains(profile.id),
                    expiresAt: profile.cachedExpiresAt,
                    onTap: {
                        model.setActiveProfile(id: profile.id)
                        Task { _ = await model.pingProfile(profile) }
                    },
                    onLongPress: { deleteProfileId = profile.id }
                )
                .contextMenu {
                    if profile.cachedIsAdmin == true {
                        Button {
                            adminProfile = profile
                        } label: {
                            Label("Admin Panel", systemImage: "shield.fill")
                        }
                    }
                    Button("Изменить") { editorProfileId = profile.id }
                    Button("Сделать активным") { model.setActiveProfile(id: profile.id) }
                    Button("Измерить пинг") { Task { _ = await model.pingProfile(profile) } }
                    Divider()
                    Button("Удалить", role: .destructive) { deleteProfileId = profile.id }
                }
            }

            GhostButton("ДОБАВИТЬ ПРОФИЛЬ", variant: .secondary) {
                showAddSheet = true
            }
        }
    }

    // MARK: - Active profile settings

    @ViewBuilder
    private func activeProfileSection(active: VpnProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("МАРШРУТИЗАЦИЯ")
            GhostCard {
                VStack(alignment: .leading, spacing: 12) {
                    dnsRow
                    HairlineDivider()
                    splitRoutingRow
                }
            }
        }
    }

    private var dnsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("DNS").gsFont(.labelMono).foregroundColor(C.textFaint)
                Spacer()
                Text(dnsDraft.isEmpty ? "СИСТЕМНЫЕ" : "НАСТРОЕНО · \(dnsDraft.count)")
                    .gsFont(.labelMonoSmall)
                    .foregroundColor(dnsDraft.isEmpty ? C.textDim : C.signal)
            }

            ForEach(Array(dnsDraft.enumerated()), id: \.offset) { (idx, server) in
                HStack(spacing: 8) {
                    Text(server)
                        .gsFont(.body)
                        .foregroundColor(C.bone)
                    Spacer()
                    Button {
                        var next = dnsDraft
                        next.remove(at: idx)
                        dnsDraft = next
                        model.setDnsServers(next)
                    } label: {
                        Text("✕").gsFont(.labelMono).foregroundColor(C.danger)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                GhostTextField("8.8.8.8", text: $newDnsEntry, keyboardType: .decimalPad)
                GhostButton("ДОБАВИТЬ", variant: .secondary, isEnabled: !newDnsEntry.isEmpty) {
                    let trimmed = newDnsEntry.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    var next = dnsDraft
                    next.append(trimmed)
                    dnsDraft = next
                    newDnsEntry = ""
                    model.setDnsServers(next)
                }
                .frame(maxWidth: 140)
            }
        }
    }

    private var splitRoutingRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("SPLIT TUNNEL")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textFaint)
                Text(splitOn ? "Активен" : "Выключен")
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
            }
            Spacer()
            GhostToggle(isOn: $splitOn, onLabel: "Split tunnel")
                .onChange(of: splitOn) { _, newValue in
                    model.setSplitRouting(newValue)
                }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("ВНЕШНИЙ ВИД")
            GhostCard {
                VStack(alignment: .leading, spacing: 14) {
                    themeRow
                    HairlineDivider()
                    languageRow
                }
            }
        }
    }

    private var themeRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ТЕМА").gsFont(.labelMono).foregroundColor(C.textFaint)
            Picker("Тема", selection: $themeSelection) {
                Text("Система").tag(ThemeOverride.system)
                Text("Тёмная").tag(ThemeOverride.dark)
                Text("Светлая").tag(ThemeOverride.light)
            }
            .pickerStyle(.segmented)
            .onChange(of: themeSelection) { _, newValue in
                model.setTheme(newValue)
            }
        }
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ЯЗЫК").gsFont(.labelMono).foregroundColor(C.textFaint)
            Picker("Язык", selection: $languageSelection) {
                Text("Система").tag("system")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            .onChange(of: languageSelection) { _, newValue in
                model.setLanguage(newValue == "system" ? nil : newValue)
            }
        }
    }

    // MARK: - Platform note

    private var platformNoteSection: some View {
        GhostCard {
            HStack(alignment: .top, spacing: 8) {
                Text("ⓘ").gsFont(.labelMono).foregroundColor(C.textDim)
                Text("Маршрутизация per-app недоступна на iOS (ограничение платформы).")
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("О ПРИЛОЖЕНИИ")
            GhostCard {
                VStack(alignment: .leading, spacing: 8) {
                    kvRow("ВЕРСИЯ",
                          (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—")
                    HairlineDivider()
                    kvRow("СБОРКА",
                          (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—")
                    HairlineDivider()
                    kvRow("КОММИТ",
                          (Bundle.main.infoDictionary?["GitCommitSHA"] as? String) ?? "—")
                }
            }
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, right: String? = nil) -> some View {
        HStack {
            Text(title).gsFont(.labelMono).foregroundColor(C.textFaint)
            if let r = right {
                Text(r).gsFont(.labelMonoSmall).foregroundColor(C.textFaint)
            }
            Spacer()
        }
    }

    private func kvRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).gsFont(.labelMonoSmall).foregroundColor(C.textDim)
            Spacer()
            Text(v).gsFont(.valueMono).foregroundColor(C.bone)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func hydrate() {
        dnsDraft = model.dnsServers
        splitOn = model.splitRouting
        themeSelection = ThemeOverride.current
        languageSelection = model.languageOverride ?? "system"
    }

    private func importConnString(_ raw: String) {
        do {
            _ = try model.importFromString(raw)
        } catch {
            importErrorText = (error as? LocalizedError)?.errorDescription ?? "Ошибка"
        }
    }
}

// MARK: - Paste sheet

/// Compact sheet with a text box + import button.
private struct PasteConnStringSheet: View {
    @Binding var text: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Вставьте строку подключения ghs://…")
                    .gsFont(.body)
                    .foregroundColor(C.textDim)

                GhostTextField("ghs://…", text: $text)
                    .frame(minHeight: 44)

                GhostButton("ИМПОРТ", variant: .primary, isEnabled: !text.isEmpty) {
                    onSubmit(text)
                    text = ""
                }

                Spacer()
            }
            .padding(18)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle("Импорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { onCancel() }
                        .foregroundColor(C.textDim)
                }
            }
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environment(\.gsColors, .dark)
            .preferredColorScheme(.dark)
    }
}
#endif
