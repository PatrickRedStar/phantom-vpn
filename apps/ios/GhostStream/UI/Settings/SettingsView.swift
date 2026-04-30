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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                endpointsSection
                routingSection
                appearanceSection
                diagnosticSection
                aboutSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(L("nav_settings"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(buildMeta)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(C.textDim)
                    .lineLimit(1)
            }
        }
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
        .task {
            hydrate()
            await model.refreshPings()
        }
        .refreshable {
            await model.refreshPings()
        }
        .confirmationDialog(L("settings.add.profile"), isPresented: $showAddDialog, titleVisibility: .visible) {
            Button(L("settings.scan.qr")) {
                showQRSheet = true
            }
            Button(L("settings.paste.connection")) {
                showPasteDialog = true
            }
            Button(L("general.cancel"), role: .cancel) {}
        }
        .confirmationDialog(L("settings.delete.profile.title"), isPresented: Binding(
            get: { deleteProfileId != nil },
            set: { if !$0 { deleteProfileId = nil } }
        ), titleVisibility: .visible) {
            Button(L("general.delete"), role: .destructive) {
                if let deleteProfileId {
                    model.deleteProfile(id: deleteProfileId)
                    self.deleteProfileId = nil
                }
            }
            Button(L("general.cancel"), role: .cancel) {
                deleteProfileId = nil
            }
        } message: {
            Text(L("settings.delete.profile.message"))
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
        .sheet(isPresented: $showPasteDialog) {
            PasteConnStringDialog(
                text: $pasteDraft,
                onSubmit: { raw in
                    importConnString(raw)
                    pasteDraft = ""
                    showPasteDialog = false
                },
                onDismiss: { showPasteDialog = false }
            )
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showDNSDialog) {
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
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSplitDialog) {
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
            .presentationDetents([.medium])
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
        .alert(
            L("settings.import.error.title"),
            isPresented: Binding(
                get: { importErrorText != nil },
                set: { if !$0 { importErrorText = nil } }
            )
        ) {
            Button(L("general.ok"), role: .cancel) {
                importErrorText = nil
            }
        } message: {
            Text(importErrorText ?? "")
        }
    }

    private var buildMeta: String {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        return String(format: L("settings.version.format"), version, build)
    }

    private var endpointsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.endpoints"), right: String(format: "%02d", model.profiles.count))

            NativeSectionCard {
                if model.profiles.isEmpty {
                    addProfileRow
                } else {
                    ForEach(Array(model.profiles.enumerated()), id: \.element.id) { idx, profile in
                        profileRow(profile)
                        if idx < model.profiles.count - 1 {
                            HairlineDivider()
                        }
                    }
                    HairlineDivider()
                    addProfileRow
                }
            }
        }
    }

    private var routingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.routing"))
            NativeSectionCard {
                VStack(spacing: 0) {
                    settingRow(
                        title: L("settings.row.dns"),
                        subtitle: dnsDraft.isEmpty ? L("settings.value.system") : dnsDraft.joined(separator: " · "),
                        value: dnsDraft.isEmpty ? L("settings.value.system") : "\(dnsDraft.count)",
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("settings.row.split.tunnel"))
                    .font(.body.weight(.semibold))
                    .foregroundColor(C.bone)
                Text(splitOn ? L("settings.split.bypass.summary") : L("settings.split.all.summary"))
                    .font(.footnote)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { splitOn },
                set: {
                    splitOn = $0
                    model.setSplitRouting($0)
                }
            ))
            .labelsHidden()
            .tint(C.signal)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            showSplitDialog = true
        }
        .padding(.vertical, 12)
    }

    private var addProfileRow: some View {
        Button {
            showAddDialog = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(C.signal)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("settings.add.profile"))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(C.bone)
                    Text(L("settings.profile.add.cta"))
                        .font(.footnote)
                        .foregroundStyle(C.textDim)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(C.textFaint)
            }
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func profileRow(_ profile: VpnProfile) -> some View {
        Button {
            selectedProfileId = profile.id
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(C.bone)
                        .lineLimit(1)
                    Text(profileSubtitle(profile))
                        .font(.footnote)
                        .foregroundStyle(C.textDim)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                profileBadge(profile)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(C.textFaint)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ForEach(profileActions(for: profile)) { action in
                Button(role: action.role) {
                    action.action()
                } label: {
                    Label(action.label, systemImage: action.systemImage)
                }
                .disabled(!action.isEnabled)
            }
        }
    }

    private func profileSubtitle(_ profile: VpnProfile) -> String {
        var parts: [String] = []
        if profile.id == model.activeId { parts.append(L("settings.profile.active")) }
        if let ping = model.pingResults[profile.id] { parts.append("\(ping) ms") }
        parts.append(profile.cachedIsAdmin == true ? L("native.profile.server.control") : L("native.profile.identity"))
        if !profile.serverAddr.isEmpty { parts.append(profile.serverAddr) }
        return parts.joined(separator: " · ")
    }

    private func profileBadge(_ profile: VpnProfile) -> some View {
        let isActive = profile.id == model.activeId
        let text = profile.cachedIsAdmin == true
            ? L("settings.profile.admin")
            : (isActive ? L("settings.profile.active") : L("settings.profile.user"))
        let color = isActive || profile.cachedIsAdmin == true ? C.signal : C.textDim
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule(style: .continuous))
            .lineLimit(1)
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("settings.section.appearance"))
            NativeSectionCard {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("settings.row.language"))
                            .font(.body.weight(.semibold))
                            .foregroundColor(C.bone)
                        Picker(L("settings.row.language"), selection: $languageSelection) {
                            Text("System").tag("system")
                            Text("RU").tag("ru")
                            Text("EN").tag("en")
                        }
                        .pickerStyle(.segmented)
                        .tint(C.signal)
                        .onChange(of: languageSelection) { _, next in
                            model.setLanguage(next == "system" ? nil : next)
                        }
                    }
                    .padding(.vertical, 12)

                    HairlineDivider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("settings.row.theme"))
                            .font(.body.weight(.semibold))
                            .foregroundColor(C.bone)
                        Picker(L("settings.row.theme"), selection: $themeSelection) {
                            Text("System").tag(ThemeOverride.system)
                            Text("Dark").tag(ThemeOverride.dark)
                            Text("Light").tag(ThemeOverride.light)
                        }
                        .pickerStyle(.segmented)
                        .tint(C.signal)
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
            NativeSectionCard {
                ShareLink(item: debugReportText) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("settings.row.share.debug"))
                                .font(.body.weight(.semibold))
                                .foregroundColor(C.bone)
                            Text(L("settings.debug.subtitle"))
                                .font(.footnote)
                                .foregroundColor(C.textDim)
                        }
                        Spacer()
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
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
            NativeSectionCard {
                VStack(alignment: .leading, spacing: 0) {
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
        NativeRow(title: title, subtitle: subtitle, action: action) {
            HStack(spacing: 12) {
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(C.signal)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(C.textFaint)
            }
        }
    }

    private func disabledPlatformRow(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(C.bone)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(C.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(L("settings.value.unavailable"))
                .font(.caption.weight(.semibold))
                .foregroundColor(C.textFaint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(C.textFaint.opacity(0.10), in: Capsule(style: .continuous))
        }
        .padding(.vertical, 12)
        .opacity(0.72)
    }

    private func sectionHeader(_ title: String, right: String? = nil) -> some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundColor(C.textDim)
            if let right {
                Text(right)
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundColor(C.textFaint)
            }
            Spacer()
        }
        .padding(.horizontal, 2)
    }

    private func kvRow(_ k: String, _ v: String) -> some View {
        HStack(spacing: 12) {
            Text(k)
                .font(.body.weight(.semibold))
                .foregroundColor(C.bone)
            Spacer()
            Text(v)
                .font(.body.monospacedDigit())
                .foregroundColor(C.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 12)
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

private struct PasteConnStringDialog: View {
    @Binding var text: String
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("settings.import.subtitle"))
                    .font(.body)
                    .foregroundColor(C.textDim)

                TextField("ghs://...", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .lineLimit(4...8)
                    .padding(12)
                    .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer(minLength: 0)
            }
            .padding(18)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("settings.import.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("general.cancel"), action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("settings.import.action")) {
                        onSubmit(text)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    NativeSectionCard {
                        ForEach(Array(presets.enumerated()), id: \.element.0) { idx, preset in
                            presetRow(name: preset.0, servers: preset.1)
                            if idx < presets.count - 1 {
                                HairlineDivider()
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("settings.dns.custom.hint"))
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(C.textDim)
                        TextField("1.1.1.1, 9.9.9.9", text: $customText, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .lineLimit(2...5)
                            .padding(12)
                            .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                .padding(18)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("settings.row.dns"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("general.cancel"), action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("general.save")) {
                        draft = customText
                            .split { $0 == "," || $0 == " " || $0 == "\n" }
                            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave()
                    }
                }
            }
        }
        .onAppear { customText = draft.joined(separator: ", ") }
    }

    private func presetRow(name: String, servers: [String]) -> some View {
        Button {
            draft = servers
            customText = servers.joined(separator: ", ")
        } label: {
            HStack {
                Text(name)
                    .font(.body.weight(.semibold))
                    .foregroundColor(draft == servers ? C.signal : C.bone)
                Spacer()
                Text(servers.joined(separator: " · "))
                    .font(.caption.monospaced())
                    .foregroundColor(C.textDim)
            }
            .padding(.vertical, 12)
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
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Picker(L("settings.split.title"), selection: $splitOn) {
                    Text(L("settings.split.mode.all")).tag(false)
                    Text(L("settings.split.mode.bypass")).tag(true)
                }
                .pickerStyle(.segmented)
                .tint(C.signal)

                NativeSectionCard {
                    infoRow(L("settings.split.cidr.title"), L("settings.split.cidr.ios"))
                    HairlineDivider()
                    infoRow(L("settings.row.per.app"), L("settings.ios.per.app.unavailable"))
                    HairlineDivider()
                    infoRow(L("settings.row.always.on"), L("settings.ios.always.on.unavailable"))
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("settings.split.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("general.cancel"), action: onDismiss)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("general.save"), action: onSave)
                }
            }
        }
    }

    private func infoRow(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundColor(C.bone)
            Text(subtitle)
                .font(.footnote)
                .foregroundColor(C.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
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
