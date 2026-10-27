//
//  ProfileEditorView.swift
//  GhostStream
//
//  Sheet for editing a single `VpnProfile`. Name and relay are editable;
//  server address / SNI / tunnel IP are read-only: they come from the conn
//  string, and the tunnel IP is assigned by the server (as on Android).
//  Actions: re-import (paste new ghs://…) and delete.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Sheet presented from the Settings list. Allows renaming, setting the
/// relay, re-importing fresh cert/key material from a new connection
/// string, and deleting the profile.
public struct ProfileEditorView: View {

    // MARK: - Inputs

    private let model: SettingsViewModel
    private let profileId: String
    private let onClose: () -> Void

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss

    // MARK: - Local state

    @State private var name: String = ""
    @State private var connStringDraft: String = ""
    @State private var relayEnabled: Bool = false
    @State private var relayAddr: String = ""
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
                    brand: L("profile.editor.title").uppercased(),
                    meta: profile?.name ?? "OFFLINE",
                    leadingLabel: "✕",
                    leadingAction: { close() }
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if let profile {
                            idSection(profile: profile)
                            endpointSection(profile: profile)
                            relaySection()
                            reimportSection()
                            GhostButton(L("general.save").uppercased(), action: { save(); close() })
                            dangerSection()
                        } else {
                            Text(L("profile.editor.not.found"))
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
                    title: L("admin.error").uppercased(),
                    message: errorMessage,
                    primaryTitle: L("general.ok"),
                    primaryAction: { self.errorMessage = nil }
                ) {
                    EmptyView()
                }
            }

            if showDeleteConfirm {
                GhostDialog(
                    title: L("settings.delete.profile.title").uppercased(),
                    message: L("profile.editor.delete.message"),
                    primaryTitle: L("general.delete").uppercased(),
                    secondaryTitle: L("general.cancel").uppercased(),
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
                Text(L("native.profile.identity").uppercased())
                    .gsFont(.labelMono)
                    .foregroundColor(C.textFaint)
                GhostTextField(
                    L("profile.editor.name.placeholder"),
                    text: $name,
                    autocapitalization: .sentences
                )
                HairlineDivider()
                kvRow("TUN", profile.tunAddr)
            }
        }
    }

    @ViewBuilder
    private func endpointSection(profile: VpnProfile) -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("profile.editor.endpoint").uppercased())
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

    /// Relay hop (ADR 0013): TCP goes to host:port, SNI stays the exit's.
    @ViewBuilder
    private func relaySection() -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $relayEnabled) {
                    Text(L("profile.relay.toggle"))
                        .gsFont(.labelMono)
                        .foregroundColor(C.textFaint)
                }
                .tint(C.signal)
                Text(L("profile.relay.desc"))
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                if relayEnabled {
                    GhostTextField("host:port", text: $relayAddr, keyboardType: .URL)
                }
            }
        }
    }

    @ViewBuilder
    private func reimportSection() -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("profile.editor.reimport").uppercased())
                    .gsFont(.labelMono)
                    .foregroundColor(C.textFaint)
                GhostTextField("ghs://…", text: $connStringDraft)
                GhostButton(L("profile.editor.apply").uppercased(), variant: .secondary) {
                    guard !connStringDraft.isEmpty else { return }
                    do {
                        try model.reimport(id: profileId, rawConnString: connStringDraft)
                        connStringDraft = ""
                    } catch {
                        errorMessage = (error as? LocalizedError)?.errorDescription
                            ?? L("profile.editor.parse.failed")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dangerSection() -> some View {
        GhostCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("profile.editor.danger").uppercased())
                    .gsFont(.labelMono)
                    .foregroundColor(C.danger)
                GhostButton(L("profile.delete").uppercased(), variant: .secondary) {
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
        relayEnabled = p.relayEnabled ?? false
        relayAddr = p.relayAddr ?? ""
    }

    private func save() {
        guard var p = profile else { return }
        let newName = name.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty { p.name = newName }
        var relay = relayAddr.trimmingCharacters(in: .whitespacesAndNewlines)
        // No port typed → the exit's port, as Android does.
        if !relay.isEmpty && !relay.contains(":") {
            relay += ":" + (p.serverAddr.split(separator: ":").dropFirst().last.map(String.init) ?? "443")
        }
        p.relayEnabled = relayEnabled
        p.relayAddr = relay.isEmpty ? nil : relay
        ProfilesStore.shared.update(p)
    }

    private func close() {
        onClose()
        dismiss()
    }

    private func L(_ key: String) -> String {
        AppStrings.localized(key)
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
