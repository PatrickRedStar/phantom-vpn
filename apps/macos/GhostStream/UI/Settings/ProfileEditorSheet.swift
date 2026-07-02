//
//  ProfileEditorSheet.swift
//  GhostStream (macOS)
//
//  CRUD профилей: список карточек + единая форма редактирования (все поля
//  видны сразу, включая relay) + импорт по ghs://-ссылке.
//  Rounded-редизайн 2026-07 (мокап editor-rounded.html / full-rounded §6).
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
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle()
                .fill(C.hair)
                .frame(height: 1)
                .padding(.top, 14)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let editingId,
                       let profile = profiles.profiles.first(where: { $0.id == editingId }) {
                        editorForm(for: profile)
                    } else {
                        listSection
                        importSection
                            .padding(.top, 20)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 480, height: 560)
        .background(RoundedRectangle(cornerRadius: GsRadius.window, style: .continuous).fill(C.bg))
    }

    // MARK: - Header (title + custom close ✕)

    private var header: some View {
        HStack(spacing: 0) {
            if let editingId,
               let profile = profiles.profiles.first(where: { $0.id == editingId }) {
                Text("\(L("profile.edit")) · \(profile.name)")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.2 * 11)
                    .foregroundStyle(C.textFaint)
            } else {
                Text("PROFILES · \(profiles.profiles.count)")
                    .font(.custom("DepartureMono-Regular", size: 11))
                    .tracking(0.2 * 11)
                    .foregroundStyle(C.textFaint)
            }
            Spacer()
            closeButton
        }
    }

    /// Кастомный крестик ✕ в рамке вместо нативной кнопки «Закрыть».
    private var closeButton: some View {
        Button {
            if editingId != nil {
                cancelEditing()
            } else {
                dismiss()
            }
        } label: {
            Text("✕")
                .font(.system(size: 12))
                .foregroundStyle(C.textDim)
                .frame(width: 26, height: 26)
                .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.hairBold, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Profile list (rounded cards)

    @ViewBuilder
    private var listSection: some View {
        if profiles.profiles.isEmpty {
            Text(L("roster.empty"))
                .font(Typography.body)
                .foregroundStyle(C.textFaint)
                .padding(.vertical, 16)
        } else {
            VStack(spacing: 8) {
                ForEach(profiles.profiles) { profile in
                    profileCard(profile)
                }
            }
        }
    }

    private func profileCard(_ profile: VpnProfile) -> some View {
        let isActive = profile.id == profiles.activeId
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.custom("SpaceGrotesk-Bold", size: 15))
                    .tracking(-0.01 * 15)
                    .foregroundStyle(C.bone)
                Text(profile.serverAddr)
                    .font(.custom("JetBrainsMono-Regular", size: 10))
                    .foregroundStyle(C.textFaint)
            }
            Spacer()
            HStack(spacing: 14) {
                Button {
                    beginEditing(profile)
                } label: {
                    Text(L("profile.edit"))
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .tracking(0.14 * 9.5)
                        .foregroundStyle(C.signal)
                }
                .buttonStyle(.plain)
                Button {
                    profiles.remove(id: profile.id)
                } label: {
                    Text(L("profile.delete"))
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .tracking(0.14 * 9.5)
                        .foregroundStyle(C.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous)
                .fill(isActive ? C.signal.opacity(0.05) : C.bgElev2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: GsRadius.card, style: .continuous)
                .stroke(isActive ? C.signalDim : C.hairBold, lineWidth: 1)
        )
    }

    // MARK: - Import by link

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldLabel(L("profile.add.title"))

            TextField(L("profile.field.name"), text: $newName)
                .textFieldStyle(.plain)
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .foregroundStyle(C.bone)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(C.bgElev))
                .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.hair, lineWidth: 1))

            TextField("ghs://…", text: $newGhs, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .foregroundStyle(C.bone)
                .lineLimit(4, reservesSpace: true)
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(C.bgElev))
                .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.hair, lineWidth: 1))
                .padding(.top, 8)

            if let err = importError {
                Text(err)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .foregroundStyle(C.danger)
                    .padding(.top, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            formButton(L("profile.import"), prominent: true, disabled: newGhs.isEmpty) {
                importProfile()
            }
            .padding(.top, 16)
        }
    }

    // MARK: - Editor form (single form, everything visible)

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
                formButton(L("logs.clear.confirm.cancel"), prominent: false, disabled: false) {
                    cancelEditing()
                }
                formButton(L("profile.save"), prominent: true, disabled: editName.isEmpty || editEndpoint.isEmpty) {
                    saveEditing(profile)
                }
            }
            .padding(.top, 20)
        }
    }

    /// Relay — дополнительный хоп между клиентом и exit-сервером
    /// (SNI-passthrough, шифрование end-to-end). Настройка профиля,
    /// в ghs://-экспорт не попадает.
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

    // MARK: - Editing lifecycle

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
