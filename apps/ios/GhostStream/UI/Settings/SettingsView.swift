//
//  SettingsView.swift
//  GhostStream
//
//  «Настройки»: profiles (tap the circle = make active, the row = editor
//  sheet), server control for admin profiles, routing, app. Adding a
//  profile lives in the «+» toolbar menu.
//

import PhantomKit
import PhantomUI
import SwiftUI
import UIKit

/// Root SwiftUI view for the Settings tab.
public struct SettingsView: View {

    @State private var model = SettingsViewModel()
    @State private var showAddDialog = false
    @State private var showDNSDialog = false
    @State private var showSplitDialog = false
    @State private var showQRSheet = false
    @State private var editorProfileId: String? = nil
    @State private var importErrorText: String? = nil
    @State private var adminProfile: VpnProfile? = nil
    @State private var dnsDraft: [String] = []
    @State private var splitOn = false
    @State private var splitSaveError: String?
    @State private var directCountrySelections: Set<String> = []
    @State private var manualDirectCidrsText = ""
    @State private var customDirectDomainsText = ""
    @State private var themeSelection: ThemeOverride = .system
    @State private var languageSelection = "system"

    @Environment(\.gsColors) private var C
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Set by the Dashboard's empty-state row: open the add-profile dialog.
    @Binding private var addProfileRequest: Bool

    public init(addProfileRequest: Binding<Bool> = .constant(false)) {
        self._addProfileRequest = addProfileRequest
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "\(L("settings.profiles")) · \(model.profiles.count)")
                profilesCard
                serverSection
                SectionLabel(text: L("settings.section.connection"))
                connectionCard
                SectionLabel(text: L("settings.section.routing"))
                routingCard
                SectionLabel(text: L("settings.section.app"))
                appCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(L("nav_settings"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    addProfileActions
                } label: {
                    Label(L("settings.add.profile"), systemImage: "plus")
                }
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
            await model.refreshSubscriptions()
        }
        .refreshable {
            await model.refreshPings()
            await model.refreshSubscriptions()
        }
        .task(id: addProfileRequest) {
            guard addProfileRequest else { return }
            addProfileRequest = false
            showAddDialog = true
        }
        .confirmationDialog(L("settings.add.profile"), isPresented: $showAddDialog, titleVisibility: .visible) {
            addProfileActions
            Button(L("general.cancel"), role: .cancel) {}
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
        // Swipe-down skips Cancel: drafts go back to what is saved.
        .sheet(isPresented: $showDNSDialog, onDismiss: { dnsDraft = model.dnsServers }) {
            DNSDialog(
                draft: $dnsDraft,
                onSave: {
                    model.setDnsServers(dnsDraft)
                    showDNSDialog = false
                },
                onDismiss: {
                    showDNSDialog = false
                }
            )
            // Medium cut the custom-DNS field off on the SE.
            .presentationDetents([.fraction(0.7), .large])
        }
        .sheet(isPresented: $showSplitDialog, onDismiss: hydrateRouteDrafts) {
            SplitTunnelDialog(
                splitOn: $splitOn,
                selectedCountries: $directCountrySelections,
                manualCidrsText: $manualDirectCidrsText,
                directDomainsText: $customDirectDomainsText,
                saveError: $splitSaveError,
                downloadedRules: model.downloadedRoutingRules,
                downloadingRuleIds: model.downloadingRoutingRuleIds,
                downloadStatus: model.routingDownloadStatus,
                onDownload: { preset in
                    Task { await model.downloadRulePreset(preset) }
                },
                onDownloadSelected: {
                    Task { await model.downloadCountryRules(Array(directCountrySelections).sorted()) }
                },
                onSave: {
                    Task {
                        // On failure the sheet stays open with the reason.
                        splitSaveError = await model.saveRoutingSettings(
                            splitOn: splitOn,
                            selectedCountries: Array(directCountrySelections).sorted(),
                            manualCidrsText: manualDirectCidrsText,
                            directDomainsText: customDirectDomainsText
                        )
                        if splitSaveError == nil { showSplitDialog = false }
                    }
                },
                onDismiss: {
                    showSplitDialog = false
                }
            )
            .presentationDetents([.large])
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

    @ViewBuilder
    private var addProfileActions: some View {
        Button {
            showQRSheet = true
        } label: {
            Label(L("settings.scan.qr"), systemImage: "qrcode.viewfinder")
        }
        Button {
            pasteFromClipboard()
        } label: {
            Label(L("settings.paste.clipboard"), systemImage: "doc.on.clipboard")
        }
    }

    // MARK: - Profiles

    private var profilesCard: some View {
        NativeSectionCard {
            if model.profiles.isEmpty {
                NativeRow(
                    title: L("settings.add.profile"),
                    subtitle: L("settings.profile.add.cta"),
                    action: { showAddDialog = true }
                )
            } else {
                ForEach(Array(model.profiles.enumerated()), id: \.element.id) { idx, profile in
                    profileRow(profile)
                    if idx < model.profiles.count - 1 {
                        HairlineDivider()
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: VpnProfile) -> some View {
        let isActive = profile.id == model.activeId
        // Accessibility sizes: the days badge goes under the name, which
        // otherwise collapsed to «Н…».
        let large = typeSize.isAccessibilitySize
        let days = daysBadge(profile).map { days in
            Text(days.text)
                .gsFont(.labelMonoSmall)
                .foregroundStyle(days.color)
        }
        return HStack(spacing: 12) {
            Button {
                model.setActiveProfile(id: profile.id)
            } label: {
                ZStack {
                    if isActive {
                        Circle().fill(C.signal)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(C.bg)
                    } else {
                        Circle().strokeBorder(C.textFaint, lineWidth: 1.5)
                    }
                }
                .frame(width: 22, height: 22)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, -11)
            .accessibilityLabel(L(isActive ? "settings.profile.active" : "settings.profile.make.active"))

            Button {
                editorProfileId = profile.id
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                            .font(.custom(GsFontName.spaceGroteskBold, size: 17))
                            .foregroundStyle(C.bone)
                            .lineLimit(1)
                            .minimumScaleFactor(large ? 0.5 : 1)
                        Text(routeSubtitle(profile))
                            .font(.custom(GsFontName.jetBrainsMono, size: 10))
                            .foregroundStyle(C.textDim)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if large { days }
                    }
                    Spacer(minLength: 8)
                    if !large { days }
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(C.textDim)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
    }

    private func routeSubtitle(_ profile: VpnProfile) -> String {
        profile.relayActive
            ? "\(L("kv_route_relay")) · \(profile.effectiveServerAddr)"
            : "\(L("kv_route_direct")) · \(profile.serverAddr)"
    }

    /// «167 Д» — lime, under two weeks orange, expired / disabled red.
    private func daysBadge(_ profile: VpnProfile) -> (text: String, color: Color)? {
        if profile.cachedEnabled == false {
            return (L("admin.tag.off").uppercased(), C.danger)
        }
        guard let expiresAt = profile.cachedExpiresAt else {
            return profile.cachedEnabled != nil ? ("∞", C.textDim) : nil
        }
        let remaining = expiresAt - Int64(Date().timeIntervalSince1970)
        guard remaining > 0 else {
            return (L("profile.subscription.expired").uppercased(), C.danger)
        }
        let days = remaining / 86_400
        return (String(format: L("settings.profile.days.format"), days).uppercased(), days < 14 ? C.warn : C.signal)
    }

    /// Admin console stays in Settings and only for admin profiles.
    @ViewBuilder
    private var serverSection: some View {
        let admins = model.profiles.filter { $0.cachedIsAdmin == true }
        if !admins.isEmpty {
            SectionLabel(text: L("settings.section.server"))
            NativeSectionCard {
                ForEach(Array(admins.enumerated()), id: \.element.id) { idx, profile in
                    NativeRow(
                        title: L("native.profile.server.control"),
                        subtitle: profile.name,
                        action: { adminProfile = profile }
                    )
                    if idx < admins.count - 1 {
                        HairlineDivider()
                    }
                }
            }
        }
    }

    // MARK: - Connection

    private var connectionCard: some View {
        NativeSectionCard {
            NativeToggleRow(
                title: L("settings.row.on.demand"),
                subtitle: L("settings.on.demand.subtitle"),
                isOn: Binding(get: { model.onDemand }, set: { model.setOnDemand($0) })
            )
            HairlineDivider()
            NativeToggleRow(
                title: L("settings.row.kill.switch"),
                subtitle: L(splitOn ? "settings.kill.switch.split" : "settings.kill.switch.subtitle"),
                isOn: Binding(get: { model.killSwitch }, set: { model.setKillSwitch($0) })
            )
            .disabled(splitOn)
        }
    }

    // MARK: - Routing

    private var routingCard: some View {
        NativeSectionCard {
            valueRow(
                title: L("settings.row.dns"),
                value: (dnsDraft.isEmpty
                    ? model.activeProfile?.dnsServers ?? SettingsViewModel.defaultDnsServers
                    : dnsDraft).joined(separator: " · "),
                action: { showDNSDialog = true }
            )
            HairlineDivider()
            valueRow(title: L("settings.row.split.tunnel"), value: splitValue) {
                hydrateRouteDrafts()
                showSplitDialog = true
            }
        }
    }

    private var splitValue: String {
        guard splitOn else { return L("settings.value.off") }
        guard !directCountrySelections.isEmpty else { return L("settings.split.bypass.summary") }
        let codes = directCountrySelections.sorted().map { $0.uppercased() }.joined(separator: ", ")
        return String(format: L("settings.split.value.format"), codes)
    }

    // MARK: - App

    private var appCard: some View {
        NativeSectionCard {
            NativeToggleRow(
                title: L("settings.row.live.activity"),
                subtitle: L("settings.live.activity.subtitle"),
                isOn: Binding(get: { model.liveActivity }, set: { model.setLiveActivity($0) })
            )
            HairlineDivider()
            pickerRow(L("settings.row.theme"), value: themeTitle(themeSelection)) {
                Picker(L("settings.row.theme"), selection: $themeSelection) {
                    ForEach(ThemeOverride.allCases, id: \.self) { Text(themeTitle($0)).tag($0) }
                }
            }
            .onChange(of: themeSelection) { _, next in
                model.setTheme(next)
            }
            HairlineDivider()
            pickerRow(L("settings.row.language"), value: languageTitle(languageSelection)) {
                Picker(L("settings.row.language"), selection: $languageSelection) {
                    ForEach(["system", "ru", "en"], id: \.self) { Text(languageTitle($0)).tag($0) }
                }
            }
            .onChange(of: languageSelection) { _, next in
                model.setLanguage(next == "system" ? nil : next)
            }
            HairlineDivider()
            ShareLink(item: debugReportText) {
                HStack(spacing: 12) {
                    rowTitle(L("settings.row.share.debug"))
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(C.signal)
                }
                .frame(minHeight: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HairlineDivider()
            HStack(spacing: 12) {
                rowTitle(L("settings.about.version"))
                Spacer()
                Text(versionText)
                    .font(.custom(GsFontName.jetBrainsMono, size: 11))
                    .foregroundStyle(C.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minHeight: 48)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "—"
        let build = (info?["CFBundleVersion"] as? String) ?? "—"
        let sha = (info?["GitCommitSHA"] as? String) ?? "—"
        return "\(version) (\(build)) · \(sha)"
    }

    // MARK: - Row helpers

    private func rowTitle(_ text: String) -> some View {
        Text(text)
            .font(.custom(GsFontName.jetBrainsMono, size: 13))
            .foregroundStyle(C.bone)
    }

    private func valueRow(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                rowTitle(title)
                Spacer(minLength: 12)
                Text(value)
                    .font(.custom(GsFontName.jetBrainsMono, size: 11))
                    .foregroundStyle(C.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(C.textDim)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Row with the current value; tapping opens a native menu picker.
    private func pickerRow<P: View>(_ title: String, value: String, @ViewBuilder picker: () -> P) -> some View {
        Menu {
            picker()
        } label: {
            HStack(spacing: 12) {
                rowTitle(title)
                Spacer(minLength: 12)
                Text(value)
                    .font(.custom(GsFontName.jetBrainsMono, size: 11))
                    .foregroundStyle(C.textDim)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(C.textDim)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func themeTitle(_ theme: ThemeOverride) -> String {
        switch theme {
        case .system: return L("settings.theme.system")
        case .dark:   return L("settings.theme.dark")
        case .light:  return L("settings.theme.light")
        }
    }

    private func languageTitle(_ code: String) -> String {
        switch code {
        case "ru": return L("settings.language.ru")
        case "en": return L("settings.language.en")
        default:   return L("settings.language.system")
        }
    }

    // MARK: - Actions

    private func hydrate() {
        dnsDraft = model.dnsServers
        hydrateRouteDrafts()
        themeSelection = model.theme
        languageSelection = model.languageOverride ?? "system"
    }

    private func hydrateRouteDrafts() {
        model.refreshDownloadedRoutingRules()
        splitOn = model.splitRouting
        directCountrySelections = Set(model.directCountries)
        manualDirectCidrsText = model.manualDirectCidrsText
        customDirectDomainsText = model.customDirectDomainsText
    }

    private func pasteFromClipboard() {
        guard let raw = UIPasteboard.general.string, !raw.isEmpty else {
            importErrorText = L("settings.import.clipboard.empty")
            return
        }
        importConnString(raw)
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
            "direct_countries=\(directCountrySelections.sorted().joined(separator: ","))",
            "manual_direct_cidrs=\(RoutePolicySnapshot.normalizedCidrs(from: manualDirectCidrsText).valid.joined(separator: ","))",
            "manual_direct_ipv6_cidrs=\(RoutePolicySnapshot.normalizedIPv6Cidrs(from: manualDirectCidrsText).valid.joined(separator: ","))",
            "custom_direct_domains=\(PreferencesStore.normalizedHostnames(from: customDirectDomainsText).joined(separator: ","))",
            "language=\(model.languageOverride ?? "system")",
            "last_logs=unavailable from Settings on iOS"
        ].joined(separator: "\n")
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
                        if !invalidEntries.isEmpty {
                            Text(String(format: L("settings.dns.invalid.format"), invalidEntries.joined(separator: ", ")))
                                .font(.footnote)
                                .foregroundColor(C.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("settings.row.dns"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Label(L("general.cancel"), systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        draft = SettingsViewModel.dnsEntries(customText)
                        onSave()
                    } label: {
                        Label(L("general.save"), systemImage: "checkmark")
                    }
                    .disabled(!invalidEntries.isEmpty)
                }
            }
        }
        .onAppear { customText = draft.joined(separator: ", ") }
    }

    private var invalidEntries: [String] {
        SettingsViewModel.dnsEntries(customText).filter { !SettingsViewModel.isValidDnsServer($0) }
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
    @Binding var selectedCountries: Set<String>
    @Binding var manualCidrsText: String
    @Binding var directDomainsText: String
    @Binding var saveError: String?
    let downloadedRules: [String: RoutingRuleInfo]
    let downloadingRuleIds: Set<String>
    let downloadStatus: String?
    let onDownload: (RoutingRulePreset) -> Void
    let onDownloadSelected: () -> Void
    let onSave: () -> Void
    let onDismiss: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker(L("settings.split.title"), selection: $splitOn) {
                        Text(L("settings.split.mode.all")).tag(false)
                        Text(L("settings.split.mode.bypass")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .tint(C.signal)

                    infoBanner

                    NativeSectionCard {
                        ForEach(Array(RoutingRulesManager.countryPresets.enumerated()), id: \.element.id) { idx, preset in
                            countryPresetRow(preset)
                            if idx < RoutingRulesManager.countryPresets.count - 1 {
                                HairlineDivider()
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button(L("settings.split.download.selected"), action: onDownloadSelected)
                            .buttonStyle(.bordered)
                            .disabled(selectedCountries.isEmpty)
                        Spacer()
                        Text(String(format: L("settings.split.selected.count"), selectedCountries.count))
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(C.textDim)
                    }

                    if let downloadStatus, !downloadStatus.isEmpty {
                        Text(downloadStatus)
                            .font(.footnote)
                            .foregroundColor(C.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    editableRulesCard

                    NativeSectionCard {
                        infoRow(
                            L("settings.split.geosite.title"),
                            L("settings.split.geosite.body")
                        )
                    }
                }
                .padding(18)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("settings.split.title"))
            .navigationBarTitleDisplayMode(.inline)
            // Icon buttons, as in the profile editor: text pills squeezed
            // the inline title down to «Раздельный т…».
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onDismiss) {
                        Label(L("general.cancel"), systemImage: "xmark")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onSave) {
                        Label(L("general.save"), systemImage: "checkmark")
                    }
                }
            }
            .alert(
                L("admin.error"),
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button(L("general.ok"), role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(splitOn ? L("settings.split.mode.bypass") : L("settings.split.mode.all"))
                .font(.body.weight(.semibold))
                .foregroundColor(splitOn ? C.signal : C.bone)
            Text(splitOn ? L("settings.split.bypass.detail") : L("settings.split.all.summary"))
                .font(.footnote)
                .foregroundColor(C.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var editableRulesCard: some View {
        NativeSectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("settings.split.custom.cidrs"))
                    .font(.body.weight(.semibold))
                    .foregroundColor(C.bone)
                Text(L("settings.split.custom.cidrs.hint"))
                    .font(.footnote)
                    .foregroundColor(C.textDim)
                TextField("8.8.8.0/24\n1.1.1.1/32", text: $manualCidrsText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .lineLimit(4...8)
                    .padding(12)
                    .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                let invalid = RoutePolicySnapshot.normalizedCidrs(from: manualCidrsText).invalid
                    .filter { !RoutePolicySnapshot.isValidIPv6Cidr($0) }
                if !invalid.isEmpty {
                    Text(String(format: L("settings.split.invalid.cidrs"), invalid.joined(separator: ", ")))
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HairlineDivider()

                Text(L("settings.split.custom.domains"))
                    .font(.body.weight(.semibold))
                    .foregroundColor(C.bone)
                Text(L("settings.split.custom.domains.hint"))
                    .font(.footnote)
                    .foregroundColor(C.textDim)
                TextField("example.com\ndomain:apple.com", text: $directDomainsText, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .lineLimit(4...8)
                    .padding(12)
                    .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.vertical, 12)
        }
    }

    private func countryPresetRow(_ preset: RoutingRulePreset) -> some View {
        let selected = selectedCountries.contains(preset.code)
        let info = downloadedRules[preset.id]
        let downloading = downloadingRuleIds.contains(preset.id)

        return HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3.weight(.semibold))
                .foregroundColor(selected ? C.signal : C.textFaint)

            VStack(alignment: .leading, spacing: 3) {
                Text(L(preset.labelKey))
                    .font(.body.weight(.semibold))
                    .foregroundColor(C.bone)
                Text(countryInfoText(info, source: preset.source))
                    .font(.footnote)
                    .foregroundColor(C.textDim)
            }

            Spacer(minLength: 12)

            Button {
                onDownload(preset)
            } label: {
                Text(downloadButtonTitle(info: info, downloading: downloading))
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(info == nil ? C.signal : C.textDim)
            .disabled(downloading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if selected {
                selectedCountries.remove(preset.code)
            } else {
                selectedCountries.insert(preset.code)
            }
        }
        .padding(.vertical, 12)
    }

    private func downloadButtonTitle(info: RoutingRuleInfo?, downloading: Bool) -> String {
        if downloading { return L("settings.split.downloading") }
        return info == nil ? L("settings.split.download") : L("settings.split.downloaded")
    }

    private func countryInfoText(_ info: RoutingRuleInfo?, source: RoutingRuleSource) -> String {
        guard let info else {
            return source == .geoip
                ? L("settings.split.geoip.not.downloaded")
                : L("settings.split.geosite.not.downloaded")
        }
        return String(format: L("settings.split.rule.info"), info.ruleCount, info.sizeKb)
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
    }
}

private func L(_ key: String) -> String {
    AppStrings.localized(key)
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
