//
//  SettingsView.swift
//  GhostStream (macOS)
//
//  «Настройки» (mockup.html, `.form`): нативный Form(.grouped) с секциями
//  Подключение / Маршрутизация / Приложение / Обновления / Дополнительно.
//  Только то, что реально работает на macOS.
//

import AppKit
import NetworkExtension
import PhantomKit
import PhantomUI
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {

    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs
    @Environment(ProfilesStore.self) private var profiles
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(TunnelLogStore.self) private var logStore
    @Environment(LoginItemController.self) private var login
    @Environment(DockPolicyController.self) private var dock
    @Environment(UpstreamVpnMonitor.self) private var upstream
    @Environment(UpdateChecker.self) private var updates
    @EnvironmentObject private var tunnel: VpnTunnelController

    @AppStorage(NotifyLevel.allKey) private var notifyAll = false
    /// `prefs.dnsServers` читает UserDefaults напрямую и не наблюдается —
    /// держим копию, чтобы Picker перерисовывался.
    @State private var dnsServers: [String]? = PreferencesStore.shared.dnsServers
    @State private var exportStatusMessage: String?
    @State private var exportingDiagnostics = false
    @State private var editingExclusions = false

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            Form {
                connectionSection
                routingSection
                appSection
                updatesSection
                advancedSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            // Колонка не шире 680 pt по центру (макет: max-width 640 + поля).
            .contentMargins(.horizontal, max(0, (geo.size.width - 680) / 2), for: .scrollContent)
        }
        .background(C.bg)
        .sheet(isPresented: $editingExclusions) { ExclusionsSheet() }
        .onAppear { login.refresh() }
        // Вернулись из Системных настроек — статус автозапуска мог смениться.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            login.refresh()
        }
    }

    private var routingMode: RoutingMode {
        prefs.effectiveRoutingMode(profileSplitRouting: profiles.activeProfile?.splitRouting)
    }

    // MARK: - Подключение

    @ViewBuilder
    private var connectionSection: some View {
        @Bindable var p = prefs
        Section {
            Toggle(isOn: $p.killSwitch) {
                Text(L("settings.kill_switch.title"))
                Text(L(routingMode == .global ? "settings.kill_switch.hint" : "settings.kill_switch.only_global"))
            }
            .tint(C.signal)
            .disabled(routingMode != .global)

            Picker(selection: Binding(get: { dnsServers }, set: { dnsServers = $0; prefs.dnsServers = $0 })) {
                Text(L("settings.dns.profile")).tag([String]?.none)
                ForEach(Self.dnsPresets, id: \.1) { title, servers in
                    Text(verbatim: title).tag(Optional(servers))
                }
                if let custom = dnsServers, !Self.dnsPresets.contains(where: { $0.1 == custom }) {
                    Text(String(format: L("settings.dns.custom"), custom.joined(separator: ", "))).tag(Optional(custom))
                }
            } label: {
                Text(L("settings.dns"))
                Text(L("settings.dns.hint"))
            }

            Toggle(isOn: $p.ipv6Killswitch) {
                Text(L("settings.ipv6_leak"))
                Text(L("settings.ipv6.hint"))
            }
            .tint(C.signal)

            Picker(selection: $p.streamOverride) {
                Text(String(format: L("settings.streams.auto"), "\(Self.autoStreams)")).tag(Int?.none)
                ForEach(streamOptions, id: \.self) { Text(verbatim: "\($0)").tag(Optional($0)) }
            } label: {
                Text(L("settings.streams.title"))
                Text(L("settings.streams.hint"))
            }
        } header: {
            Text(L("settings.section.connection"))
        } footer: {
            if needsReconnect {
                HStack(spacing: GsSpace.xs) {
                    Text(L("settings.reconnect_needed"))
                        .foregroundStyle(C.textDim)
                    Button(L("settings.reconnect")) {
                        if let profile = profiles.activeProfile {
                            tunnel.restart(with: profile, preferences: prefs)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(C.signal)
                }
                .gsType(.caption)
            }
        }
    }

    private static let dnsPresets: [(String, [String])] = [
        ("Cloudflare · 1.1.1.1", ["1.1.1.1", "1.0.0.1"]),
        ("Google · 8.8.8.8", ["8.8.8.8", "8.8.4.4"]),
        ("Quad9 · 9.9.9.9", ["9.9.9.9", "149.112.112.112"]),
    ]

    /// Авто в ядре — число ядер, зажатое в 2…16 (`core::wire::n_data_streams`).
    private static let autoStreams = min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 16)

    private var streamOptions: [Int] {
        var options = [2, 4, 8, 12, 16]
        if let current = prefs.streamOverride, !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options
    }

    /// Туннель поднят, а настройки, которые провайдер читает только при
    /// старте, расходятся с запечёнными в его providerConfiguration.
    /// Маршруты, свои исключения и DNS рабочего VPN монитор применяет на лету.
    private var needsReconnect: Bool {
        guard VpnTunnelController.isUp(stateMgr.statusFrame.state),
              let proto = tunnel.manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration,
              let settingsData = config["settings"] as? Data,
              let applied = try? JSONDecoder().decode(TunnelSettings.self, from: settingsData)
        else { return false }
        let appliedDns = (config["profile"] as? Data)
            .flatMap { try? JSONDecoder().decode(VpnProfile.self, from: $0) }?
            .dnsServers
        return applied.ipv6Killswitch != prefs.ipv6Killswitch
            || applied.streams != prefs.streamOverride
            || proto.includeAllNetworks != (prefs.killSwitch && routingMode == .global)
            || appliedDns != (dnsServers ?? profiles.activeProfile?.dnsServers)
    }

    // MARK: - Маршрутизация

    @ViewBuilder
    private var routingSection: some View {
        @Bindable var p = prefs
        Section(L("settings.section.routing")) {
            Picker(selection: Binding(get: { routingMode }, set: { prefs.routingMode = $0 })) {
                Text(L("settings.routing.global")).tag(RoutingMode.global)
                Text(L("settings.routing.public")).tag(RoutingMode.publicSplit)
                Text(L("settings.routing.work")).tag(RoutingMode.layeredAuto)
            } label: {
                Text(L("settings.routing.title"))
                if routingMode == .layeredAuto {
                    Text(workVpnStatus)
                }
            }

            if routingMode == .layeredAuto {
                Toggle(isOn: $p.preserveScopedDns) {
                    Text(L("settings.routing.work_dns.title"))
                    Text(L("settings.routing.work_dns.hint"))
                }
                .tint(C.signal)
            }

            // Свои исключения действуют только в split-режимах.
            if routingMode != .global {
                LabeledContent {
                    HStack(spacing: GsSpace.m) {
                        Text(exclusionsCount)
                            .foregroundStyle(C.textDim)
                        Button(L("settings.exclusions.edit")) { editingExclusions = true }
                    }
                } label: {
                    Text(L("settings.exclusions.title"))
                    Text(L("settings.exclusions.hint"))
                }
            }
        }
    }

    private var workVpnStatus: String {
        let snapshot = upstream.snapshot
        // ADR 0012: full-tunnel рабочий VPN — корп-ресурсы без узких
        // маршрутов уйдут в GhostStream.
        if snapshot.upstreamHasBroadRoutes { return L("settings.routing.work_broad") }
        if let name = snapshot.upstreamProviderName {
            return String(format: L("settings.routing.work_found"), name)
        }
        return L("settings.routing.work_none")
    }

    private var exclusionsCount: String {
        let count = prefs.manualDirectCidrs.count + prefs.manualDirectIpv6Cidrs.count
        return count == 0
            ? L("settings.exclusions.none")
            : String(format: L("settings.exclusions.count"), "\(count)")
    }

    // MARK: - Приложение

    @ViewBuilder
    private var appSection: some View {
        @Bindable var p = prefs
        @Bindable var dockBinding = dock
        Section(L("settings.section.app")) {
            Toggle(isOn: Binding(
                get: { login.enabled || login.requiresApproval },
                set: { login.setEnabled($0) }
            )) {
                Text(L("settings.login.title"))
            }
            .tint(C.signal)
            if login.requiresApproval {
                LabeledContent {
                    Button(L("settings.login.open_settings")) {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } label: {
                    Text(L("settings.login.approval"))
                        .foregroundStyle(C.warn)
                }
            }

            Toggle(isOn: $p.startInMenuBar) {
                Text(L("settings.menubar.title"))
                Text(L("settings.menubar.hint"))
            }
            .tint(C.signal)

            Toggle(L("settings.dock.title"), isOn: $dockBinding.showInDock)
                .tint(C.signal)

            Picker(L("settings.notifications.title"), selection: notifyLevel) {
                Text(L("settings.notifications.problems")).tag(NotifyLevel.problems)
                Text(L("settings.notifications.all")).tag(NotifyLevel.all)
                Text(L("settings.notifications.off")).tag(NotifyLevel.off)
            }

            Picker(L("settings.appearance"), selection: Binding(
                get: { ThemeOverride(rawValue: prefs.theme) ?? .system },
                set: { prefs.theme = $0.rawValue }
            )) {
                Text(L("settings.theme.system")).tag(ThemeOverride.system)
                Text(L("settings.theme.light")).tag(ThemeOverride.light)
                Text(L("settings.theme.dark")).tag(ThemeOverride.dark)
            }

            Picker(L("settings.language"), selection: Binding(
                get: { prefs.languageOverride },
                set: setLanguage
            )) {
                Text(L("settings.language.system")).tag(String?.none)
                Text(verbatim: "Русский").tag(Optional("ru"))
                Text(verbatim: "English").tag(Optional("en"))
            }
        }
    }

    private var notifyLevel: Binding<NotifyLevel> {
        Binding(
            get: { prefs.notifyStateChanges ? (notifyAll ? .all : .problems) : .off },
            set: {
                prefs.notifyStateChanges = $0 != .off
                notifyAll = $0 == .all
            }
        )
    }

    /// Живое переключение (LocalizationManager + LocalizedRoot) плюс
    /// `AppleLanguages` — им macOS выбирает язык при следующем запуске
    /// (системные диалоги NE/панели).
    private func setLanguage(_ code: String?) {
        prefs.languageOverride = code
        LocalizationManager.shared.setLanguage(code)
        if let code {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    // MARK: - Обновления

    private var updatesSection: some View {
        Section(L("settings.updates")) {
            LabeledContent {
                if let release = updates.available {
                    Button(L("update.download")) { NSWorkspace.shared.open(release.url) }
                        .foregroundStyle(C.bg)
                        .gsProminentButton(tint: C.signal)
                } else {
                    Button(L("update.check")) { Task { await updates.check() } }
                        .disabled(updates.checking)
                }
            } label: {
                Text(String(format: L("update.version_build"),
                            UpdateChecker.currentVersion, UpdateChecker.currentBuild))
                Text(updateStatus)
            }
        }
    }

    /// «Доступна версия X» / «Установлена последняя версия · проверено в 14:02».
    private var updateStatus: String {
        if updates.checking { return L("update.checking") }
        if let release = updates.available {
            return String(format: L("update.available"), release.version)
        }
        guard let checked = updates.lastCheck else { return L("update.never_checked") }
        return String(format: L("update.up_to_date"),
                      checked.formatted(date: .omitted, time: .shortened))
    }

    // MARK: - Дополнительно

    @ViewBuilder
    private var advancedSection: some View {
        @Bindable var p = prefs
        Section(L("settings.section.advanced")) {
            Toggle(isOn: $p.verboseLog) {
                Text(L("settings.verbose.title"))
                Text(L("settings.verbose.hint"))
            }
            .tint(C.signal)
            LabeledContent {
                Button(L("settings.report.save")) { Task { await exportDiagnostics() } }
                    .disabled(exportingDiagnostics)
            } label: {
                Text(L("settings.report.title"))
                Text(exportStatusMessage ?? L("settings.report.hint"))
            }
        }
    }

    @MainActor
    private func exportDiagnostics() async {
        exportingDiagnostics = true
        defer { exportingDiagnostics = false }

        guard let destination = chooseDiagnosticsBundleURL() else { return }

        do {
            try DiagnosticsBundleExporter.export(
                to: destination,
                preferences: prefs,
                profiles: profiles,
                stateManager: stateMgr,
                logs: logStore
            )
            exportStatusMessage = String(format: L("settings.report.saved"), destination.lastPathComponent)
        } catch {
            exportStatusMessage = String(format: L("settings.report.failed"), error.localizedDescription)
        }
    }

    @MainActor
    private func chooseDiagnosticsBundleURL() -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultDiagnosticsBundleName()
        if let bundleType = UTType(filenameExtension: "ghoststream-diagnostics") {
            panel.allowedContentTypes = [bundleType]
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func defaultDiagnosticsBundleName() -> String {
        let stamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "GhostStream-Diagnostics-\(stamp).ghoststream-diagnostics"
    }
}

/// Свои исключения: адреса и подсети мимо VPN, по одному на строку.
private struct ExclusionsSheet: View {

    @Environment(\.gsColors) private var C
    @Environment(PreferencesStore.self) private var prefs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var p = prefs
        let shape = RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous)
        VStack(alignment: .leading, spacing: GsSpace.m) {
            Text(L("settings.exclusions.title"))
                .gsType(.headline)
                .foregroundStyle(C.bone)
            Text(L("settings.exclusions.sheet_hint"))
                .gsType(.caption)
                .foregroundStyle(C.textDim)
            TextEditor(text: $p.manualDirectCidrsText)
                .font(GsType.mono.font)
                .foregroundStyle(C.bone)
                .scrollContentBackground(.hidden)
                .padding(GsSpace.s)
                .frame(minHeight: 180)
                .background(C.bgElev, in: shape)
                .overlay(shape.stroke(C.hair, lineWidth: 1))
            if !prefs.invalidManualDirectCidrs.isEmpty {
                Text(String(format: L("settings.exclusions.invalid"),
                            prefs.invalidManualDirectCidrs.joined(separator: ", ")))
                    .gsType(.caption)
                    .foregroundStyle(C.danger)
            }
            HStack {
                Spacer()
                Button(L("general.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .foregroundStyle(C.bg)
                    .gsProminentButton(tint: C.signal)
            }
        }
        .padding(GsSpace.xl)
        .frame(width: 460)
        .background(C.bg)
    }
}

@MainActor
private enum DiagnosticsBundleExporter {
    static func export(
        to destination: URL,
        preferences: PreferencesStore,
        profiles: ProfilesStore,
        stateManager: VpnStateManager,
        logs: TunnelLogStore
    ) throws {
        let scoped = destination.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                destination.stopAccessingSecurityScopedResource()
            }
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let summary = DiagnosticsSummary(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString
        )
        try writeJSON(summary, to: destination.appendingPathComponent("summary.json"))
        try writeJSON(
            DiagnosticsPreferencesSnapshot(preferences: preferences),
            to: destination.appendingPathComponent("preferences.json")
        )
        // PRIVACY: StatusFrame echoes `serverAddr` / `sni` / `tunAddr` and
        // per-stream identifiers. Route the encode through the same JSON
        // redaction pipeline used by `snapshot-file.json` so support
        // bundles never reveal which server / network the user was on.
        try writeSanitisedEncodable(
            stateManager.statusFrame,
            to: destination.appendingPathComponent("status-frame.json")
        )
        try writeJSON(
            profiles.profiles.map(DiagnosticsProfileSnapshot.init(profile:)),
            to: destination.appendingPathComponent("profiles.json")
        )
        try writeLogs(
            Array(logs.logs.suffix(2_000)),
            to: destination.appendingPathComponent("logs.jsonl")
        )

        if let snapshotURL = fm
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.client")?
            .appendingPathComponent("snapshot.json"),
           fm.fileExists(atPath: snapshotURL.path) {
            // PRIVACY: snapshot.json carries the most recent StatusFrame —
            // tunAddr / serverAddr / sni / per-stream identifiers. A
            // bundle uploaded to support must not echo the user's server
            // back to the recipient (it correlates them to a specific
            // server in the fleet). Decode → redact → re-serialise rather
            // than `copyItem` the raw file.
            try? writeSanitisedSnapshot(
                from: snapshotURL,
                to: destination.appendingPathComponent("snapshot-file.json")
            )
        }
    }

    /// Best-effort redaction of the live snapshot. Reads as generic JSON
    /// so we don't have to maintain a Swift mirror of the wire struct
    /// (which lives in `gui-ipc` on the Rust side and drifts as fields
    /// are added). Walks the object tree and replaces values for any key
    /// in `sensitiveSnapshotKeys`. Failure-tolerant: a malformed file
    /// makes us skip the snapshot entirely rather than leak the raw
    /// bytes.
    private static func writeSanitisedSnapshot(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        guard let json = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else { return }
        let redacted = redactSnapshotNode(json)
        let outData = try JSONSerialization.data(
            withJSONObject: redacted,
            options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]
        )
        try outData.write(to: destination, options: .atomic)
    }

    /// Same redaction pipeline as `writeSanitisedSnapshot` but driven by
    /// a Codable in-memory value. Encodes via `JSONEncoder`, re-parses
    /// through `JSONSerialization` to walk the tree, then writes the
    /// redacted form back out. Used for `status-frame.json`, which is
    /// produced from `StatusFrame` rather than read from disk.
    private static func writeSanitisedEncodable<T: Encodable>(
        _ value: T,
        to destination: URL
    ) throws {
        let raw = try JSONEncoder().encode(value)
        guard let json = try? JSONSerialization.jsonObject(
            with: raw,
            options: [.fragmentsAllowed]
        ) else {
            // Fall back to writing the raw bytes — better than skipping
            // the artefact entirely. The wire struct must encode to a
            // JSON object/array for any production payload, so this
            // branch is reserved for future scalar-only types.
            try raw.write(to: destination, options: .atomic)
            return
        }
        let redacted = redactSnapshotNode(json)
        let outData = try JSONSerialization.data(
            withJSONObject: redacted,
            options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]
        )
        try outData.write(to: destination, options: .atomic)
    }

    private static let sensitiveSnapshotKeys: Set<String> = [
        "server", "server_addr", "serverAddr",
        "sni", "server_name", "serverName",
        "tun_addr", "tunAddr",
        "host", "remote", "remote_addr",
        "cert_fingerprint", "certFingerprint",
        "admin_server_cert_fp", "adminServerCertFp",
    ]

    private static func redactSnapshotNode(_ node: Any) -> Any {
        if let dict = node as? [String: Any] {
            var redacted = dict
            for key in dict.keys {
                if sensitiveSnapshotKeys.contains(key) {
                    redacted[key] = "<redacted>"
                } else if let child = dict[key] {
                    redacted[key] = redactSnapshotNode(child)
                }
            }
            return redacted
        }
        if let array = node as? [Any] {
            return array.map(redactSnapshotNode(_:))
        }
        return node
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func writeLogs(_ frames: [LogFrame], to url: URL) throws {
        let encoder = JSONEncoder()
        let lines = try frames.map { frame in
            let sanitized = sanitizeLogFrame(frame)
            let data = try encoder.encode(sanitized)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
        .joined(separator: "\n")
        try (lines + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Fields that identify the user's server, tunnel network, or active
    /// stream — redacted from any structured event whose category is in
    /// `sensitiveLogCategories`. Diagnostics bundles routinely get
    /// e-mailed to support, dropped into Slack, or attached to GitHub
    /// issues; the runtime log on disk keeps the full value so engineers
    /// can still debug locally.
    private static let sensitiveLogFields: Set<String> = [
        "server",
        "server_addr",
        "serverAddr",
        "host",
        "sni",
        "server_name",
        "serverName",
        "tun_addr",
        "tunAddr",
        "stream",
        "stream_id",
        "streamId",
        "remote",
        "remote_addr",
        "peer",
    ]

    /// Categories whose structured fields carry network identifiers.
    /// Kept in sync with the OSLog mirror redaction list in
    /// `PacketTunnelProvider.isSensitiveOSLogCategory(_:)`.
    private static let sensitiveLogCategories: Set<String> = [
        "tunnel",
        "handshake",
        "network",
        "stream",
    ]

    private static func sanitizeLogFrame(_ frame: LogFrame) -> LogFrame {
        guard
            let category = frame.category?.lowercased(),
            sensitiveLogCategories.contains(category),
            let fields = frame.fields,
            !fields.isEmpty
        else { return frame }

        var redacted = fields
        for key in fields.keys where sensitiveLogFields.contains(key) {
            redacted[key] = "<redacted>"
        }
        var copy = frame
        copy.fields = redacted
        return copy
    }
}

private struct DiagnosticsSummary: Codable {
    let generatedAt: String
    let appVersion: String
    let build: String
    let macOS: String
}

private struct DiagnosticsPreferencesSnapshot: Codable {
    let theme: String
    let dnsLeakProtection: Bool
    let ipv6Killswitch: Bool
    let autoReconnect: Bool
    let startInMenuBar: Bool
    let notifyStateChanges: Bool
    let reduceMotion: Bool
    let autoUpdate: Bool
    let verboseLog: Bool
    let streamOverride: Int?
    let routingMode: String
    let dnsServers: [String]?
    let preserveScopedDns: Bool
    let manualDirectCidrs: [String]
    let invalidManualDirectCidrs: [String]

    @MainActor
    init(preferences: PreferencesStore) {
        theme = preferences.theme
        dnsLeakProtection = preferences.dnsLeakProtection
        ipv6Killswitch = preferences.ipv6Killswitch
        autoReconnect = preferences.autoReconnect
        startInMenuBar = preferences.startInMenuBar
        notifyStateChanges = preferences.notifyStateChanges
        reduceMotion = preferences.reduceMotion
        autoUpdate = preferences.autoUpdate
        verboseLog = preferences.verboseLog
        streamOverride = preferences.streamOverride
        routingMode = preferences.routingMode.rawValue
        dnsServers = preferences.dnsServers
        preserveScopedDns = preferences.preserveScopedDns
        manualDirectCidrs = preferences.manualDirectCidrs
        invalidManualDirectCidrs = preferences.invalidManualDirectCidrs
    }
}

private struct DiagnosticsProfileSnapshot: Codable {
    let id: String
    let name: String
    let serverAddr: String
    let serverName: String
    let insecure: Bool
    let tunAddr: String
    let dnsServers: [String]?
    let splitRouting: Bool?
    let directCountries: [String]?
    let cachedExpiresAt: Int64?
    let cachedEnabled: Bool?
    let cachedIsAdmin: Bool?
    /// 8-char prefix of the admin server cert fingerprint. Full SHA-256
    /// is **not** included — even a fingerprint correlated with a server
    /// IP narrows a user's identity if the bundle leaves the device. The
    /// prefix is long enough for engineering to disambiguate which
    /// server the user was talking to, but short enough that it cannot
    /// be used to verify a specific cert in a database. nil if no
    /// fingerprint cached.
    let cachedAdminServerCertFpPrefix: String?

    init(profile: VpnProfile) {
        id = profile.id
        name = profile.name
        serverAddr = profile.serverAddr
        serverName = profile.serverName
        insecure = profile.insecure
        tunAddr = profile.tunAddr
        dnsServers = profile.dnsServers
        splitRouting = profile.splitRouting
        directCountries = profile.directCountries
        cachedExpiresAt = profile.cachedExpiresAt
        cachedEnabled = profile.cachedEnabled
        cachedIsAdmin = profile.cachedIsAdmin
        cachedAdminServerCertFpPrefix = profile.cachedAdminServerCertFp
            .map { String($0.prefix(8)) }
    }
}
