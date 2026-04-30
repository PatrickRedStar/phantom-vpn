//
//  SettingsView.swift
//  GhostStream
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Root SwiftUI view for the Settings tab.
public struct SettingsView: View {

    @State private var model = SettingsViewModel()
    @State private var showAddDialog = false
    @State private var showPasteDialog = false
    @State private var showDNSDialog = false
    @State private var showSplitDialog = false
    @State private var showQRSheet = false
    @State private var pasteDraft = ""
    @State private var selectedProfileId: String? = nil
    @State private var editorProfileId: String? = nil
    @State private var deleteProfileId: String? = nil
    @State private var importErrorText: String? = nil
    @State private var adminProfile: VpnProfile? = nil
    @State private var dnsDraft: [String] = []
    @State private var splitOn = false
    @State private var themeSelection: ThemeOverride = .system
    @State private var languageSelection = "system"

    @Environment(\.gsColors) private var C

    public init() {}

    public var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        endpointsSection
                        routingSection
                        appearanceSection
                        diagnosticSection
                        aboutSection
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { selectedProfileId != nil },
                set: { if !$0 { selectedProfileId = nil } }
            )) {
                if let id = selectedProfileId,
                   let profile = model.profiles.first(where: { $0.id == id }) {
                    ProfileDetailView(
                        profile: profile,
                        isActive: profile.id == model.activeId,
                        pingMs: model.pingResults[profile.id],
                        onSetActive: {
                            model.setActiveProfile(id: profile.id)
                            selectedProfileId = nil
                        },
                        onEdit: {
                            editorProfileId = profile.id
                        },
                        onDelete: {
                            deleteProfileId = profile.id
                            selectedProfileId = nil
                        },
                        onOpenAdmin: {
                            guard profile.cachedIsAdmin == true else { return }
                            adminProfile = profile
                        }
                    )
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { adminProfile != nil },
                set: { if !$0 { adminProfile = nil } }
            )) {
                if let p = adminProfile {
                    AdminView(profile: p)
                }
            }

            if showAddDialog {
                AddProfileDialog(
                    onPaste: {
                        showAddDialog = false
                        showPasteDialog = true
                    },
                    onScan: {
                        showAddDialog = false
                        showQRSheet = true
                    },
                    onDismiss: { showAddDialog = false }
                )
            }

            if showPasteDialog {
                PasteConnStringDialog(
                    text: $pasteDraft,
                    onSubmit: { raw in
                        importConnString(raw)
                        pasteDraft = ""
                        showPasteDialog = false
                    },
                    onDismiss: { showPasteDialog = false }
                )
            }

            if showDNSDialog {
                DNSDialog(
                    draft: $dnsDraft,
                    onSave: {
                        model.setDnsServers(dnsDraft)
                        showDNSDialog = false
                    },
                    onDismiss: {
                        dnsDraft = model.dnsServers
                        showDNSDialog = false
                    }
                )
            }

            if showSplitDialog {
                SplitTunnelDialog(
                    splitOn: $splitOn,
                    onSave: {
                        model.setSplitRouting(splitOn)
                        showSplitDialog = false
                    },
                    onDismiss: {
                        splitOn = model.splitRouting
                        showSplitDialog = false
                    }
                )
            }

            if let importErrorText {
                GhostDialogFrame(title: L("settings.import.error.title"), onDismiss: { self.importErrorText = nil }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(importErrorText)
                            .gsFont(.body)
                            .foregroundColor(C.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                        GhostButton(L("general.ok"), action: { self.importErrorText = nil })
                    }
                }
            }

            if let deleteProfileId {
                GhostDialogFrame(title: L("settings.delete.profile.title"), onDismiss: { self.deleteProfileId = nil }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("settings.delete.profile.message"))
                            .gsFont(.body)
                            .foregroundColor(C.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            GhostButton(L("general.cancel"), variant: .secondary) {
                                self.deleteProfileId = nil
                            }
                            GhostButton(L("general.delete")) {
                                model.deleteProfile(id: deleteProfileId)
                                self.deleteProfileId = nil
                            }
                        }
                    }
                }
            }
        }
        .task {
            hydrate()
            await model.refreshPings()
        }
        .refreshable {
            await model.refreshPings()
        }
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
        .sheet(isPresented: Binding(
            get: { editorProfileId != nil },
            set: { if !$0 { editorProfileId = nil } }
        )) {
            if let id = editorProfileId {
                ProfileEditorView(model: model, profileId: id, onClose: { editorProfileId = nil })
                    .environment(\.gsColors, C)
            }
        }
    }

    private var header: some View {
        ScreenHeader(brand: L("brand_settings"), meta: buildMeta)
    }

    private var buildMeta: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return String(format: L("settings.version.format"), version, build)
    }

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.endpoints"), right: String(format: "· %02d", model.profiles.count))

            ForEach(model.profiles, id: \.id) { profile in
                ProfileCard(
                    profile: profile,
                    isActive: profile.id == model.activeId,
                    pingMs: model.pingResults[profile.id],
                    isPinging: model.pinging.contains(profile.id),
                    expiresAt: profile.cachedExpiresAt,
                    onTap: {
                        selectedProfileId = profile.id
                    },
                    onLongPress: { deleteProfileId = profile.id },
                    actions: profileActions(for: profile)
                )
            }

            DashedProfileCTA {
                showAddDialog = true
            }
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.routing"))
            GhostCard {
                VStack(spacing: 0) {
                    settingRow(
                        title: L("settings.row.dns"),
                        subtitle: dnsDraft.isEmpty ? L("settings.value.system") : dnsDraft.joined(separator: " · "),
                        value: dnsDraft.isEmpty ? L("settings.value.system").uppercased() : "\(dnsDraft.count)",
                        action: { showDNSDialog = true }
                    )
                    HairlineDivider()
                    splitRoutingRow
                    HairlineDivider()
                    disabledPlatformRow(
                        title: L("settings.row.per.app"),
                        subtitle: L("settings.ios.per.app.unavailable")
                    )
                    HairlineDivider()
                    disabledPlatformRow(
                        title: L("settings.row.always.on"),
                        subtitle: L("settings.ios.always.on.unavailable")
                    )
                }
            }
        }
    }

    private var splitRoutingRow: some View {
        Button {
            showSplitDialog = true
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.row.split.tunnel").uppercased())
                        .gsFont(.labelMono)
                        .foregroundColor(C.textFaint)
                    Text(splitOn ? L("settings.split.bypass.summary") : L("settings.split.all.summary"))
                        .gsFont(.body)
                        .foregroundColor(C.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                GhostToggle(isOn: Binding(
                    get: { splitOn },
                    set: {
                        splitOn = $0
                        model.setSplitRouting($0)
                    }
                ), onLabel: L("settings.row.split.tunnel"))
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.appearance"))
            GhostCard {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("settings.row.language").uppercased())
                            .gsFont(.labelMono)
                            .foregroundColor(C.textFaint)
                        LangSwitch(selected: $languageSelection)
                            .onChange(of: languageSelection) { _, next in
                                model.setLanguage(next == "system" ? nil : next)
                            }
                    }
                    .padding(.vertical, 12)

                    HairlineDivider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("settings.row.theme").uppercased())
                            .gsFont(.labelMono)
                            .foregroundColor(C.textFaint)
                        ThemeSwitch(selected: $themeSelection)
                            .onChange(of: themeSelection) { _, next in
                                model.setTheme(next)
                            }
                    }
                    .padding(.vertical, 12)

                    HairlineDivider()

                    disabledPlatformRow(
                        title: L("settings.row.app.icon"),
                        subtitle: L("settings.ios.app.icon.unavailable")
                    )
                }
            }
        }
    }

    private var diagnosticSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.diagnostic"))
            GhostCard {
                ShareLink(item: debugReportText) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("settings.row.share.debug").uppercased())
                                .gsFont(.labelMono)
                                .foregroundColor(C.textFaint)
                            Text(L("settings.debug.subtitle"))
                                .gsFont(.body)
                                .foregroundColor(C.textDim)
                        }
                        Spacer()
                        Text(L("settings.value.export").uppercased())
                            .gsFont(.labelMonoSmall)
                            .foregroundColor(C.signal)
                    }
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.about"))
            GhostCard {
                VStack(alignment: .leading, spacing: 8) {
                    kvRow(L("settings.about.version"), (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—")
                    HairlineDivider()
                    kvRow(L("settings.about.build"), (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—")
                    HairlineDivider()
                    kvRow(L("settings.about.commit"), (Bundle.main.infoDictionary?["GitCommitSHA"] as? String) ?? "—")
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func settingRow(
        title: String,
        subtitle: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.uppercased()).gsFont(.labelMono).foregroundColor(C.textFaint)
                    Text(subtitle).gsFont(.body).foregroundColor(C.textDim).lineLimit(2)
                }
                Spacer()
                Text(value.uppercased())
                    .gsFont(.labelMonoSmall)
                    .foregroundColor(C.signal)
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func disabledPlatformRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).gsFont(.labelMono).foregroundColor(C.textFaint)
                Text(subtitle)
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(L("settings.value.unavailable").uppercased())
                .gsFont(.labelMonoSmall)
                .foregroundColor(C.textFaint)
        }
        .padding(.vertical, 12)
        .opacity(0.58)
    }

    private func sectionHeader(_ title: String, right: String? = nil) -> some View {
        HStack {
            Text(title.uppercased()).gsFont(.labelMono).foregroundColor(C.textFaint)
            if let right {
                Text(right).gsFont(.labelMonoSmall).foregroundColor(C.textFaint)
            }
            Spacer()
        }
    }

    private func kvRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k.uppercased()).gsFont(.labelMonoSmall).foregroundColor(C.textDim)
            Spacer()
            Text(v).gsFont(.valueMono).foregroundColor(C.bone)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func profileActions(for profile: VpnProfile) -> [ProfileCardAction] {
        let isActive = profile.id == model.activeId
        return [
            ProfileCardAction(
                label: isActive ? L("settings.profile.active") : L("settings.profile.make.active"),
                systemImage: isActive ? "checkmark.circle.fill" : "checkmark.circle",
                isEnabled: !isActive
            ) {
                model.setActiveProfile(id: profile.id)
            },
            ProfileCardAction(label: L("settings.profile.ping"), systemImage: "speedometer") {
                Task { _ = await model.pingProfile(profile) }
            },
            ProfileCardAction(label: L("general.edit"), systemImage: "pencil") {
                editorProfileId = profile.id
            },
            ProfileCardAction(
                label: L("general.delete"),
                systemImage: "trash",
                role: .destructive
            ) {
                deleteProfileId = profile.id
            }
        ]
    }

    private func hydrate() {
        dnsDraft = model.dnsServers
        splitOn = model.splitRouting
        themeSelection = model.theme
        languageSelection = model.languageOverride ?? "system"
    }

    private func importConnString(_ raw: String) {
        do {
            _ = try model.importFromString(raw)
        } catch {
            importErrorText = (error as? LocalizedError)?.errorDescription ?? L("settings.import.error.fallback")
        }
    }

    private var debugReportText: String {
        let active = model.activeProfile
        return [
            "GhostStream iOS debug report",
            "version=\((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—")",
            "build=\((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—")",
            "profiles=\(model.profiles.count)",
            "active_profile=\(active?.name ?? "—")",
            "server=\(active?.serverAddr ?? "—")",
            "dns=\(model.dnsServers.isEmpty ? "system" : model.dnsServers.joined(separator: ","))",
            "split_routing=\(model.splitRouting)",
            "language=\(model.languageOverride ?? "system")",
            "last_logs=unavailable from Settings on iOS"
        ].joined(separator: "\n")
    }
}

private struct DashedProfileCTA: View {
    let action: () -> Void
    @Environment(\.gsColors) private var C

    var body: some View {
        DashedGhostCard(action: action) {
            Text(L("settings.profile.add.cta").uppercased())
                .gsFont(.labelMono)
                .foregroundColor(C.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

private struct GhostDialogFrame<Content: View>: View {
    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.gsColors) private var C

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea().onTapGesture { onDismiss() }
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title.uppercased())
                        .gsFont(.labelMono)
                        .foregroundColor(C.bone)
                    Spacer()
                    Button(action: onDismiss) {
                        Text("×")
                            .gsFont(.valueMono)
                            .foregroundColor(C.textDim)
                    }
                    .buttonStyle(.plain)
                }
                content()
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(C.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(C.hairBold, lineWidth: 1)
                    )
            )
            .padding(.horizontal, 22)
        }
    }
}

private struct AddProfileDialog: View {
    let onPaste: () -> Void
    let onScan: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GhostDialogFrame(title: L("settings.add.profile"), onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                GhostButton(L("settings.scan.qr"), variant: .primary, action: onScan)
                GhostButton(L("settings.paste.connection"), variant: .secondary, action: onPaste)
                GhostButton(L("general.cancel"), variant: .secondary, action: onDismiss)
            }
        }
    }
}

private struct PasteConnStringDialog: View {
    @Binding var text: String
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        GhostDialogFrame(title: L("settings.import.title"), onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("settings.import.subtitle"))
                    .gsFont(.body)
                    .foregroundColor(C.textDim)
                GhostTextField("ghs://…", text: $text)
                HStack(spacing: 10) {
                    GhostButton(L("general.cancel"), variant: .secondary, action: onDismiss)
                    GhostButton(L("settings.import.action"), isEnabled: !text.isEmpty) {
                        onSubmit(text)
                    }
                }
            }
        }
    }
}

private struct DNSDialog: View {
    @Binding var draft: [String]
    let onSave: () -> Void
    let onDismiss: () -> Void

    @State private var customText = ""
    @Environment(\.gsColors) private var C

    private let presets: [(String, [String])] = [
        ("Cloudflare", ["1.1.1.1", "1.0.0.1"]),
        ("Google", ["8.8.8.8", "8.8.4.4"]),
        ("Quad9", ["9.9.9.9", "149.112.112.112"]),
        ("AdGuard", ["94.140.14.14", "94.140.15.15"])
    ]

    var body: some View {
        GhostDialogFrame(title: L("settings.row.dns"), onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(presets, id: \.0) { preset in
                    presetRow(name: preset.0, servers: preset.1)
                    HairlineDivider()
                }
                GhostTextField(L("settings.dns.custom.hint"), text: $customText)
                    .onAppear { customText = draft.joined(separator: ", ") }
                HStack(spacing: 10) {
                    GhostButton(L("general.cancel"), variant: .secondary, action: onDismiss)
                    GhostButton(L("general.save")) {
                        draft = customText
                            .split { $0 == "," || $0 == " " || $0 == "\n" }
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave()
                    }
                }
            }
        }
    }

    private func presetRow(name: String, servers: [String]) -> some View {
        Button {
            draft = servers
            customText = servers.joined(separator: ", ")
        } label: {
            HStack {
                Text(name)
                    .gsFont(.profileName)
                    .foregroundColor(draft == servers ? C.signal : C.bone)
                Spacer()
                Text(servers.joined(separator: " · "))
                    .gsFont(.labelMonoSmall)
                    .foregroundColor(C.textDim)
            }
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }
}

private struct SplitTunnelDialog: View {
    @Binding var splitOn: Bool
    let onSave: () -> Void
    let onDismiss: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        GhostDialogFrame(title: L("settings.split.title"), onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    modeButton(L("settings.split.mode.all"), selected: !splitOn) { splitOn = false }
                    modeButton(L("settings.split.mode.bypass"), selected: splitOn) { splitOn = true }
                }
                HairlineDivider()
                infoRow(L("settings.split.cidr.title"), L("settings.split.cidr.ios"))
                HairlineDivider()
                infoRow(L("settings.row.per.app"), L("settings.ios.per.app.unavailable"))
                HairlineDivider()
                infoRow(L("settings.row.always.on"), L("settings.ios.always.on.unavailable"))
                HStack(spacing: 10) {
                    GhostButton(L("general.cancel"), variant: .secondary, action: onDismiss)
                    GhostButton(L("general.save"), action: onSave)
                }
            }
        }
    }

    private func modeButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .gsFont(.labelMonoSmall)
                .foregroundColor(selected ? C.bg : C.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? C.signal : C.bgElev2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(selected ? C.signalDim : C.hair, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func infoRow(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).gsFont(.labelMonoSmall).foregroundColor(C.textFaint)
            Text(subtitle).gsFont(.body).foregroundColor(C.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .opacity(0.72)
    }
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
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
