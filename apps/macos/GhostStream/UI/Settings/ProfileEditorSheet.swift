//
//  ProfileEditorSheet.swift
//  GhostStream (macOS)
//
//  CRUD профилей: paste new ghs:// + name + delete.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct ProfileEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles

    @State private var newGhs: String = ""
    @State private var newName: String = ""
    @State private var importError: String?

    /// id профиля в режиме редактирования + рабочая копия полей.
    @State private var editingId: String?
    @State private var editName: String = ""
    @State private var editEndpoint: String = ""
    @State private var editSni: String = ""
    @State private var editTun: String = ""
    @State private var editRelayEnabled: Bool = false
    @State private var editRelayAddr: String = ""
    @State private var editError: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("PROFILES")
                    .font(Typography.labelMono)
                    .tracking(0.2 * 10.5)
                    .foregroundStyle(C.textFaint)
                Spacer()
                Button("Закрыть") { dismiss() }
            }

            HairlineDivider()

            if profiles.profiles.isEmpty {
                Text(L("roster.empty"))
                    .font(Typography.body)
                    .foregroundStyle(C.textFaint)
                    .padding(.vertical, 16)
            } else {
                List {
                    ForEach(profiles.profiles) { profile in
                        if editingId == profile.id {
                            editorRow(for: profile)
                        } else {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name).font(Typography.profileName).foregroundStyle(C.bone)
                                    Text(profile.serverAddr).font(Typography.host).foregroundStyle(C.textFaint)
                                }
                                Spacer()
                                Button(L("profile.edit")) {
                                    beginEditing(profile)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(C.signal)
                                Button(L("profile.delete"), role: .destructive) {
                                    profiles.remove(id: profile.id)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(C.danger)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .frame(minHeight: 160)
            }

            Text("ADD NEW")
                .font(Typography.labelMonoTiny)
                .foregroundStyle(C.textFaint)

            TextField("Имя", text: $newName)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .padding(10)
                .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))

            TextField("ghs://...", text: $newGhs, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .lineLimit(4, reservesSpace: true)
                .padding(10)
                .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))

            if let err = importError {
                Text(err)
                    .font(Typography.bodySmall)
                    .foregroundStyle(C.danger)
            }

            HStack {
                Spacer()
                Button {
                    importProfile()
                } label: {
                    Text("ИМПОРТИРОВАТЬ")
                        .font(Typography.labelMono)
                        .tracking(0.18 * 10.5)
                        .foregroundStyle(C.signal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(C.signal, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(newGhs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .background(C.bg)
    }

    // MARK: - Edit existing profile

    @ViewBuilder
    private func editorRow(for profile: VpnProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            editField(L("profile.field.name"), text: $editName)
            editField(L("profile.field.endpoint"), text: $editEndpoint, mono: true)
            editField(L("profile.field.sni"), text: $editSni, mono: true)
            editField(L("profile.field.tun"), text: $editTun, mono: true)
            relayEditor
            if let editError {
                Text(editError).font(Typography.bodySmall).foregroundStyle(C.danger)
            }
            HStack {
                Spacer()
                Button(L("logs.clear.confirm.cancel")) { cancelEditing() }
                    .buttonStyle(.plain)
                    .foregroundStyle(C.textDim)
                Button(L("profile.save")) { saveEditing(profile) }
                    .buttonStyle(.plain)
                    .foregroundStyle(C.signal)
                    .disabled(editName.isEmpty || editEndpoint.isEmpty)
            }
        }
        .padding(.vertical, 6)
    }

    /// Relay — дополнительный хоп между клиентом и exit-сервером
    /// (SNI-passthrough, шифрование end-to-end). Настройка профиля,
    /// в ghs://-экспорт не попадает.
    @ViewBuilder
    private var relayEditor: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("profile.relay.toggle"))
                    .font(Typography.body)
                    .foregroundStyle(C.bone)
                Text(L("profile.relay.desc"))
                    .font(Typography.bodySmall)
                    .foregroundStyle(C.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $editRelayEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(C.signal)
        }
        .padding(.top, 4)
        if editRelayEnabled {
            editField(L("profile.relay.addr"), text: $editRelayAddr, mono: true)
        }
    }

    @ViewBuilder
    private func editField(_ label: String, text: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Typography.labelMonoTiny).foregroundStyle(C.textFaint)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(mono ? .custom("JetBrainsMono-Regular", size: 12) : Typography.body)
                .padding(8)
                .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))
        }
    }

    private func beginEditing(_ profile: VpnProfile) {
        editingId = profile.id
        editName = profile.name
        editEndpoint = profile.serverAddr
        editSni = profile.serverName
        editTun = profile.tunAddr
        editRelayEnabled = profile.relayEnabled ?? false
        editRelayAddr = profile.relayAddr ?? ""
        editError = nil
    }

    private func cancelEditing() {
        editingId = nil
        editError = nil
    }

    private func saveEditing(_ original: VpnProfile) {
        var updated = original
        updated.name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.serverAddr = editEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.serverName = editSni.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.tunAddr = editTun.trimmingCharacters(in: .whitespacesAndNewlines)
        let relayAddr = editRelayAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.relayEnabled = editRelayEnabled
        updated.relayAddr = relayAddr.isEmpty ? nil : relayAddr

        // connString кодирует endpoint/SNI/tun — пересобираем из
        // обновлённых полей + существующих cert/key (в памяти, из
        // Keychain). Если PEM недоступны, оставляем connString пустым:
        // провайдер соберёт его сам при старте (ConnStringBuilder.build).
        updated.connString = ConnStringBuilder.build(from: updated)

        profiles.update(updated)
        editingId = nil
        editError = nil
    }

    private func importProfile() {
        do {
            let trimmed = newGhs.trimmingCharacters(in: .whitespacesAndNewlines)
            var profile = try profiles.importFromConnString(trimmed)
            if !newName.isEmpty {
                profile.name = newName
                profiles.update(profile)
            }
            newGhs = ""
            newName = ""
            importError = nil
        } catch {
            importError = "Неверная ghs:// строка"
        }
    }
}
