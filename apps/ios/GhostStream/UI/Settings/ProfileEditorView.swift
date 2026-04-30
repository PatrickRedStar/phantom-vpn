//
//  ProfileEditorView.swift
//  GhostStream
//
//  Sheet for editing a single `VpnProfile`. Name and tun CIDR are editable;
//  server address / SNI are read-only because they come from the conn string.
//  Actions: re-import (paste new ghs://…) and delete.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Sheet presented from the Settings list. Allows renaming, editing the
/// local tunnel CIDR, re-importing fresh cert/key material from a new
/// connection string, and deleting the profile.
public struct ProfileEditorView: View {

    // MARK: - Inputs

    private let model: SettingsViewModel
    private let profileId: String
    private let onClose: () -> Void

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss

    // MARK: - Local state

    @State private var name: String = ""
    @State private var tunAddr: String = ""
    @State private var connStringDraft: String = ""
    @State private var showDeleteConfirm: Bool = false
    @State private var errorMessage: String?

    // MARK: - Init

    /// Creates an editor bound to the profile with id `profileId` inside
    /// `model.profiles`. Caller should present this as a `.sheet` and
    /// dismiss via `onClose`.
    public init(
        model: SettingsViewModel,
        profileId: String,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.profileId = profileId
        self.onClose = onClose
    }

    // MARK: - Derived

    private var profile: VpnProfile? {
        model.profiles.first(where: { $0.id == profileId })
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ScreenHeader(
                    brand: "ПРОФИЛЬ",
                    meta: profile?.name ?? "OFFLINE",
                    leadingLabel: "✕",
                    leadingAction: { close() }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let profile {
                            idSection(profile: profile)
                            endpointSection(profile: profile)
                            reimportSection()
                            GhostButton("СОХРАНИТЬ", action: { save(); close() })
                            dangerSection()
                        } else {
                            Text("Профиль не найден")
                                .gsFont(.body)
                                .foregroundColor(C.textDim)
                                .padding()
                        }
                    }
                    .padding(18)
                }
            }
            .background(C.bg.ignoresSafeArea())

            if let errorMessage {
                GhostDialog(
                    title: "ОШИБКА",
                    message: errorMessage,
                    primaryTitle: "OK",
                    primaryAction: { self.errorMessage = nil }
                ) {
                    EmptyView()
                }
            }

            if showDeleteConfirm {
                GhostDialog(
                    title: "УДАЛИТЬ ПРОФИЛЬ?",
                    message: "Это действие нельзя отменить. Сертификаты и ключи будут удалены.",
                    primaryTitle: "УДАЛИТЬ",
                    secondaryTitle: "ОТМЕНА",
                    primaryAction: {
                        if let profile { model.deleteProfile(id: profile.id) }
                        showDeleteConfirm = false
                        close()
                    },
                    secondaryAction: { showDeleteConfirm = false }
                ) {
                    EmptyView()
                }
            }
        }
        .onAppear(perform: loadFromProfile)
    }

    // MARK: - Sections

    @ViewBuilder
    private func idSection(profile: VpnProfile) -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("ИДЕНТИЧНОСТЬ")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textFaint)
                GhostTextField(
                    "Имя профиля",
                    text: $name,
                    autocapitalization: .sentences
                )
                HairlineDivider()
                Text("ТУННЕЛЬ (CIDR)")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textFaint)
                GhostTextField("10.7.0.2/24", text: $tunAddr)
            }
        }
    }

    @ViewBuilder
    private func endpointSection(profile: VpnProfile) -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("ТОЧКА ВХОДА")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textFaint)
                kvRow("SERVER", profile.serverAddr)
                HairlineDivider()
                kvRow("SNI", profile.serverName)
                HairlineDivider()
                kvRow("FP", profile.cachedAdminServerCertFp ?? "—")
            }
        }
    }

    @ViewBuilder
    private func reimportSection() -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("ПЕРЕИМПОРТ СТРОКИ ПОДКЛЮЧЕНИЯ")
                    .gsFont(.labelMono)
                    .foregroundColor(C.textFaint)
                GhostTextField("ghs://…", text: $connStringDraft)
                GhostButton("ПРИМЕНИТЬ", variant: .secondary) {
                    guard !connStringDraft.isEmpty else { return }
                    do {
                        try model.reimport(id: profileId, rawConnString: connStringDraft)
                        connStringDraft = ""
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription
                            ?? "Не удалось разобрать строку"
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dangerSection() -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("ОПАСНАЯ ЗОНА")
                    .gsFont(.labelMono)
                    .foregroundColor(C.danger)
                GhostButton("УДАЛИТЬ ПРОФИЛЬ", variant: .secondary) {
                    showDeleteConfirm = true
                }
            }
        }
    }

    // MARK: - Helpers

    private func kvRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(key).gsFont(.labelMonoSmall).foregroundColor(C.textDim)
            Spacer()
            Text(value).gsFont(.valueMono).foregroundColor(C.bone)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func loadFromProfile() {
        guard let p = profile else { return }
        name = p.name
        tunAddr = p.tunAddr
    }

    private func save() {
        guard var p = profile else { return }
        let newName = name.trimmingCharacters(in: .whitespaces)
        let newTun  = tunAddr.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty { p.name = newName }
        if !newTun.isEmpty { p.tunAddr = newTun }
        model.renameProfile(id: p.id, name: p.name)
        // tunAddr is not routed through renameProfile — update directly via store:
        ProfilesStore.shared.update(p)
    }

    private func close() {
        onClose()
        dismiss()
    }
}

#if DEBUG
struct ProfileEditorView_Previews: PreviewProvider {
    static var previews: some View {
        ProfileEditorView(
            model: SettingsViewModel(),
            profileId: "preview",
            onClose: {}
        )
        .environment(\.gsColors, .dark)
    }
}
#endif
