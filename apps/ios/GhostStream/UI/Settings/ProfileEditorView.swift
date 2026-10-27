//
//  ProfileEditorView.swift
//  GhostStream
//
//  Native sheet for one `VpnProfile`: name and relay are editable; server,
//  SNI and tunnel IP come from the conn string (tunnel IP is assigned by
//  the server) and are read-only. Ping, delete, refresh keys from the
//  clipboard.
//

import PhantomKit
import PhantomUI
import SwiftUI
import UIKit

/// Sheet presented from the Settings list.
public struct ProfileEditorView: View {

    // MARK: - Inputs

    private let model: SettingsViewModel
    private let profileId: String
    private let onClose: () -> Void

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize

    // MARK: - Local state

    @State private var name: String = ""
    @State private var relayEnabled: Bool = false
    @State private var relayAddr: String = ""
    @State private var showDeleteConfirm: Bool = false
    @State private var errorMessage: String?
    @State private var pinging: Bool = false

    public init(
        model: SettingsViewModel,
        profileId: String,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.profileId = profileId
        self.onClose = onClose
    }

    private var profile: VpnProfile? {
        model.profiles.first(where: { $0.id == profileId })
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                if let profile {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: L("profile.editor.name"))
                        TextField(L("profile.editor.name.placeholder"), text: $name)
                            .font(.custom(GsFontName.jetBrainsMono, size: 15))
                            .foregroundStyle(C.bone)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 16)
                            .frame(height: 50)
                            .gsCardBackground(C, radius: 18)

                        SectionLabel(text: L("profile.editor.readonly"))
                        NativeSectionCard {
                            lockedRow(L("profile.editor.server"), profile.serverAddr)
                            HairlineDivider()
                            lockedRow("SNI", profile.serverName)
                            HairlineDivider()
                            lockedRow(L("profile.editor.tun"), profile.tunAddr)
                        }

                        SectionLabel(text: L("profile.editor.relay.section"))
                        relayCard

                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    pinging = true
                                    _ = await model.pingProfile(profile)
                                    pinging = false
                                }
                            } label: {
                                Text(pingTitle(profile).uppercased())
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(pinging)
                            .glassButtonStyle()

                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Text(L("general.delete").uppercased())
                                    .frame(maxWidth: .infinity)
                            }
                            .glassButtonStyle()
                            .tint(C.danger)
                        }
                        .font(.custom(GsFontName.departureMono, size: 11))
                        .tracking(1.5)
                        .controlSize(.large)
                        .padding(.top, 8)

                        Button {
                            reimportFromClipboard()
                        } label: {
                            Label(L("profile.editor.reimport.clipboard"), systemImage: "doc.on.clipboard")
                                .font(.custom(GsFontName.jetBrainsMono, size: 12))
                                .foregroundStyle(C.textDim)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                } else {
                    Text(L("profile.editor.not.found"))
                        .gsFont(.body)
                        .foregroundStyle(C.textDim)
                        .padding()
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("profile.editor.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        close()
                    } label: {
                        Label(L("general.cancel"), systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                        close()
                    } label: {
                        Label(L("general.save"), systemImage: "checkmark")
                    }
                    .disabled(profile == nil)
                }
            }
            .confirmationDialog(
                L("settings.delete.profile.title"),
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button(L("general.delete"), role: .destructive) {
                    model.deleteProfile(id: profileId)
                    close()
                }
                Button(L("general.cancel"), role: .cancel) {}
            } message: {
                Text(L("profile.editor.delete.message"))
            }
            .alert(
                L("admin.error"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(L("general.ok"), role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear(perform: loadFromProfile)
    }

    // MARK: - Sections

    /// Relay hop (ADR 0013): TCP goes to host:port, SNI stays the exit's.
    private var relayCard: some View {
        NativeSectionCard {
            NativeToggleRow(
                title: L("profile.relay.toggle"),
                subtitle: L("profile.relay.hint"),
                isOn: $relayEnabled
            )
            if relayEnabled {
                HairlineDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("profile.editor.relay.addr"))
                        .font(.custom(GsFontName.jetBrainsMono, size: 10))
                        .foregroundStyle(C.textDim)
                    TextField("host:port", text: $relayAddr)
                        .font(.custom(GsFontName.jetBrainsMono, size: 12))
                        .foregroundStyle(C.signal)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background(C.bg, in: Capsule())
                        .overlay(Capsule().stroke(C.hairBold, lineWidth: 1))
                }
                .padding(.vertical, 12)
            }
        }
    }

    /// Key · value on one line; at accessibility sizes the value goes
    /// under the key («Туннельный IP» broke mid-word next to it).
    private func lockedRow(_ key: String, _ value: String) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let row = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: 10))
        return row {
            Text(key)
                .font(.custom(GsFontName.jetBrainsMono, size: 13))
                .foregroundStyle(C.bone)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .layoutPriority(1)
            if !stacked { Spacer(minLength: 12) }
            HStack(spacing: 10) {
                Text(value.isEmpty ? "—" : value)
                    .font(.custom(GsFontName.jetBrainsMono, size: 11))
                    .foregroundStyle(C.textDim)
                    .lineLimit(stacked ? nil : 1)
                    .truncationMode(.middle)
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(C.textFaint)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, stacked ? 8 : 0)
        .accessibilityElement(children: .combine)
    }

    private func pingTitle(_ profile: VpnProfile) -> String {
        if pinging { return "\(L("profile.editor.ping")) · …" }
        guard let ms = model.pingResults[profile.id] else { return L("profile.editor.ping") }
        return ms < 0 ? L("profile.ping.failed") : String(format: L("profile.editor.ping.format"), ms)
    }

    // MARK: - Actions

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
        p.relayEnabled = relayEnabled
        p.relayAddr = VpnProfile.normalizedRelayAddr(relayAddr)
        ProfilesStore.shared.update(p)
    }

    /// Fresh cert/key from a new ghs:// link, same profile id and name.
    private func reimportFromClipboard() {
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else {
            errorMessage = L("settings.import.clipboard.empty")
            return
        }
        do {
            try model.reimport(id: profileId, rawConnString: raw)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? L("profile.editor.parse.failed")
        }
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
