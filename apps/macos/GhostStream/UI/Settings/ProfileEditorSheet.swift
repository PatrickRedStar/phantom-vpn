//
//  ProfileEditorSheet.swift
//  GhostStream (macOS)
//
//  Две независимые сущности, оба — модальный шит (rounded):
//   • edit-режим (init(editProfileId:)) — редактор ОДНОГО профиля
//     (имя/сервер/SNI/tun/relay), открывается кликом по ⋯ в СПИСКЕ.
//     Никакого списка профилей внутри — сам СПИСОК и есть список.
//   • new-режим (init()) — импорт нового профиля по ghs://-ссылке
//     (кнопка «+ NEW PROFILE»).
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct ProfileEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles

    /// Если задан — шит открывается сразу в режиме редактирования этого
    /// профиля. Если nil — режим импорта нового профиля.
    private let editProfileId: String?

    // new-режим
    @State private var newGhs: String = ""
    @State private var newName: String = ""
    @State private var importError: String?

    // edit-режим — рабочая копия полей
    @State private var editName: String = ""
    @State private var editEndpoint: String = ""
    @State private var editSni: String = ""
    @State private var editTun: String = ""
    @State private var editRelayEnabled: Bool = false
    @State private var editRelayAddr: String = ""
    @State private var editError: String?
    @State private var loaded = false
    @State private var showDeleteConfirm = false

    public init(editProfileId: String? = nil) {
        self.editProfileId = editProfileId
    }

    private var editingProfile: VpnProfile? {
        guard let editProfileId else { return nil }
        return profiles.profiles.first(where: { $0.id == editProfileId })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(C.hair)
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 16)

            ScrollView {
                if let profile = editingProfile {
                    editorForm(for: profile)
                } else {
                    importSection
                }
            }
        }
        .padding(22)
        .frame(width: 480, height: editProfileId != nil ? 560 : 360)
        .background(RoundedRectangle(cornerRadius: GsRadius.window, style: .continuous).fill(C.bg))
        .onAppear(perform: loadIfNeeded)
        .alert(L("profile.delete"), isPresented: $showDeleteConfirm) {
            Button(L("profile.delete"), role: .destructive) {
                if let editProfileId { profiles.remove(id: editProfileId) }
                dismiss()
            }
            Button(L("general.cancel"), role: .cancel) {}
        } message: {
            if let p = editingProfile {
                Text(String(format: L("profile.delete.confirm"), p.name))
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            if let profile = editingProfile {
                Text("\(L("profile.edit")) · \(profile.name)")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.2 * 11)
                    .foregroundStyle(C.textFaint)
            } else {
                Text(L("profile.add.title.new"))
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.2 * 11)
                    .foregroundStyle(C.textFaint)
            }
            Spacer()
            if editingProfile != nil {
                iconButton(systemName: "trash", danger: true) { showDeleteConfirm = true }
            }
            iconButton(text: "✕") { dismiss() }
        }
    }

    private func iconButton(systemName: String? = nil, text: String? = nil, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemName { Image(systemName: systemName).font(.system(size: 12)) }
                else { Text(text ?? "").font(.system(size: 12)) }
            }
            .foregroundStyle(danger ? C.danger : C.textDim)
            .frame(width: 26, height: 26)
            .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(danger ? C.danger.opacity(0.4) : C.hairBold, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - New profile (import by ghs://)

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(L("profile.field.name"))
            plainField(L("profile.field.name"), text: $newName)

            fieldLabel(L("profile.add.title"))
            TextField("ghs://…", text: $newGhs, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .foregroundStyle(C.bone)
                .lineLimit(4, reservesSpace: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(C.bgElev))
                .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.hair, lineWidth: 1))

            if let err = importError {
                Text(err)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .foregroundStyle(C.danger)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                formButton(L("logs.clear.confirm.cancel"), prominent: false, disabled: false) { dismiss() }
                formButton(L("profile.import"), prominent: true, disabled: newGhs.isEmpty) { importProfile() }
            }
            .padding(.top, 18)
        }
    }

    // MARK: - Editor form (single profile)

    @ViewBuilder
    private func editorForm(for profile: VpnProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            editField(L("profile.field.name"), text: $editName)
            editField(L("profile.field.endpoint"), text: $editEndpoint, mono: true)
            editField(L("profile.field.sni"), text: $editSni, mono: true)
            editField(L("profile.field.tun"), text: $editTun, mono: true)

            relayEditor

            if let editError {
                Text(editError)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .foregroundStyle(C.danger)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                formButton(L("logs.clear.confirm.cancel"), prominent: false, disabled: false) { dismiss() }
                formButton(L("profile.save"), prominent: true, disabled: editName.isEmpty || editEndpoint.isEmpty) {
                    saveEditing(profile)
                }
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var relayEditor: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("profile.relay.toggle"))
                    .font(.custom("SpaceGrotesk-Bold", size: 13))
                    .foregroundStyle(C.bone)
                Text(L("profile.relay.desc"))
                    .font(.custom("JetBrainsMono-Regular", size: 10))
                    .foregroundStyle(C.textFaint)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: $editRelayEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(C.signal)
                .padding(.top, 2)
        }
        .padding(.top, 14)
        .padding(.bottom, 4)

        if editRelayEnabled {
            editField(L("profile.relay.addr"), text: $editRelayAddr, mono: true, signal: true)
        }
    }

    // MARK: - Pieces

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom("DepartureMono-Regular", size: 9.5))
            .tracking(0.16 * 9.5)
            .foregroundStyle(C.textFaint)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    private func plainField(_ label: String, text: Binding<String>) -> some View {
        TextField(label, text: text)
            .textFieldStyle(.plain)
            .font(.custom("JetBrainsMono-Regular", size: 12))
            .foregroundStyle(C.bone)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(C.bgElev))
            .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.hair, lineWidth: 1))
    }

    @ViewBuilder
    private func editField(
        _ label: String,
        text: Binding<String>,
        mono: Bool = false,
        signal: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(label)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(mono ? .custom("JetBrainsMono-Regular", size: 12) : .custom("SpaceGrotesk-Regular", size: 13))
                .foregroundStyle(C.bone)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(C.bgElev))
                .overlay(
                    RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous)
                        .stroke(signal ? C.signalDim : C.hair, lineWidth: 1)
                )
        }
    }

    private func formButton(
        _ title: String,
        prominent: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("DepartureMono-Regular", size: 10))
                .tracking(0.16 * 10)
                .foregroundStyle(prominent ? C.bg : C.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(prominent ? C.signal : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(prominent ? C.signal : C.hairBold, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    // MARK: - Logic

    private func loadIfNeeded() {
        guard !loaded, let profile = editingProfile else { return }
        loaded = true
        editName = profile.name
        editEndpoint = profile.serverAddr
        editSni = profile.serverName
        editTun = profile.tunAddr
        editRelayEnabled = profile.relayEnabled ?? false
        editRelayAddr = profile.relayAddr ?? ""
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

        // connString кодирует endpoint/SNI/tun — пересобираем из обновлённых
        // полей + существующих cert/key. Если PEM недоступны — оставляем
        // пустым, провайдер соберёт сам при старте (ConnStringBuilder.build).
        updated.connString = ConnStringBuilder.build(from: updated)

        profiles.update(updated)
        dismiss()
    }

    private func importProfile() {
        do {
            let trimmed = newGhs.trimmingCharacters(in: .whitespacesAndNewlines)
            var profile = try profiles.importFromConnString(trimmed)
            if !newName.isEmpty {
                profile.name = newName
                profiles.update(profile)
            }
            dismiss()
        } catch {
            importError = "Неверная ghs:// строка"
        }
    }
}
