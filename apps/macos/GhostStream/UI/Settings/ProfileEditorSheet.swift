//
//  ProfileEditorSheet.swift
//  GhostStream (macOS)
//
//  Шит профиля, нативная Form:
//   • edit (init(editProfileId:)) — имя и реле на виду; сервер, SNI и
//     адрес в VPN — в «Дополнительно», с проверкой формата;
//   • new (init()) — добавить по ghs://-ссылке (из буфера подставляется
//     сама), без дублей.
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct ProfileEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles

    /// nil — добавление нового профиля по ссылке.
    private let editProfileId: String?

    @State private var name = ""
    @State private var link = ""
    @State private var server = ""
    @State private var sni = ""
    @State private var tun = ""
    @State private var relayOn = false
    @State private var relayAddr = ""
    @State private var showAdvanced = false
    @State private var error: String?
    @State private var loaded = false

    public init(editProfileId: String? = nil) {
        self.editProfileId = editProfileId
    }

    private var editingProfile: VpnProfile? {
        editProfileId.flatMap(profiles.load(id:))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                if editProfileId != nil {
                    editSections
                } else {
                    newSection
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(C.danger)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            buttons
        }
        .frame(width: 480, height: editProfileId != nil ? 470 : 330)
        .background(C.bg)
        .onAppear(perform: load)
    }

    // MARK: - Sections

    @ViewBuilder
    private var editSections: some View {
        Section(L("pedit.title.edit")) {
            TextField(L("profile.field.name"), text: $name)
        }
        Section {
            Toggle(L("pedit.relay"), isOn: $relayOn)
                .tint(C.signal)
            if relayOn {
                addressField(L("pedit.relay.addr"), text: $relayAddr, prompt: "host:443")
            }
        } footer: {
            Text(L("pedit.relay.hint"))
                .gsType(.caption)
                .foregroundStyle(C.textDim)
        }
        Section {
            DisclosureGroup(L("pedit.advanced"), isExpanded: $showAdvanced) {
                addressField(L("pedit.server"), text: $server, prompt: "host:port")
                addressField(L("pedit.sni"), text: $sni, prompt: "vpn.example.com")
                addressField(L("pedit.tun"), text: $tun, prompt: "10.7.0.2/24")
            }
        }
    }

    private var newSection: some View {
        Section(L("pedit.title.new")) {
            TextField(text: $link, prompt: Text("ghs://…"), axis: .vertical) {
                Text(L("pedit.link")).font(GsType.body.font)
                Text(L("pedit.link.hint")).font(GsType.caption.font)
            }
            .font(GsType.mono.font)
            .lineLimit(3...5)
            TextField(text: $name, prompt: Text(L("pedit.name.hint"))) {
                Text(L("profile.field.name"))
            }
        }
    }

    private func addressField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        TextField(text: text, prompt: Text(prompt)) {
            Text(label).font(GsType.body.font)
        }
        .font(GsType.mono.font)
    }

    private var buttons: some View {
        HStack(spacing: GsSpace.s) {
            Spacer()
            Button(L("general.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
                .gsGlassButton()
            Button(action: submit) {
                Text(L(editProfileId != nil ? "profile.save" : "pedit.add"))
                    .fontWeight(.semibold)
                    .foregroundStyle(C.bg)
                    .padding(.horizontal, GsSpace.xs)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .gsProminentButton(tint: C.signal)
            .disabled(editProfileId == nil ? link.trimmed.isEmpty : name.trimmed.isEmpty)
        }
        .padding(.horizontal, GsSpace.xl)
        .padding(.bottom, GsSpace.xl)
    }

    // MARK: - Logic

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let profile = editingProfile else {
            let clip = NSPasteboard.general.string(forType: .string)?.trimmed ?? ""
            if clip.hasPrefix("ghs://") { link = clip }
            return
        }
        name = profile.name
        server = profile.serverAddr
        sni = profile.serverName
        tun = profile.tunAddr
        relayOn = profile.relayEnabled ?? false
        relayAddr = profile.relayAddr ?? ""
    }

    private func submit() {
        if let profile = editingProfile {
            save(profile)
        } else {
            importLink()
        }
    }

    private func save(_ original: VpnProfile) {
        if let problem = ProfileFieldCheck.problem(
            name: name.trimmed, server: server.trimmed, sni: sni.trimmed,
            tun: tun.trimmed, relayOn: relayOn, relay: relayAddr.trimmed
        ) {
            error = L(problem.key)
            if problem.advanced { showAdvanced = true }
            return
        }
        var updated = original
        updated.name = name.trimmed
        updated.serverAddr = server.trimmed
        updated.serverName = sni.trimmed
        updated.tunAddr = tun.trimmed
        updated.relayEnabled = relayOn
        // Без порта → :443, как на iOS (реле слушают 443, не 8443 exit'а).
        updated.relayAddr = VpnProfile.normalizedRelayAddr(relayAddr)
        // Другой сервер — другой серт админки: TOFU-пин закрепляем заново.
        if updated.serverAddr != original.serverAddr || updated.serverName != original.serverName {
            updated.cachedAdminServerCertFp = nil
        }
        // connString кодирует endpoint/SNI/tun — пересобираем из полей и
        // PEM; без PEM провайдер соберёт сам при старте.
        updated.connString = ConnStringBuilder.build(from: updated)
        profiles.update(updated)
        dismiss()
    }

    private func importLink() {
        switch profiles.importLink(link) {
        case .added(var profile):
            if !name.trimmed.isEmpty {
                profile.name = name.trimmed
                profiles.update(profile)
            }
            dismiss()
        case .duplicate(let profile):
            error = String(format: L("srv.notice.duplicate"), profile.name)
        case .notALink, .invalid:
            error = L("srv.notice.invalid")
        }
    }
}

// MARK: - Validation

/// Проверка полей профиля: одна опечатка в адресе — вечный реконнект.
enum ProfileFieldCheck {

    struct Problem: Equatable {
        let key: String
        /// Поле в «Дополнительно» — раскрыть его.
        let advanced: Bool
    }

    static func problem(name: String, server: String, sni: String, tun: String,
                        relayOn: Bool, relay: String) -> Problem? {
        if name.isEmpty { return Problem(key: "pedit.err.name", advanced: false) }
        if relayOn && !(isHostPort(relay) || isHost(relay)) {
            return Problem(key: "pedit.err.relay", advanced: false)
        }
        if !isHostPort(server) { return Problem(key: "pedit.err.server", advanced: true) }
        if !isDomain(sni) { return Problem(key: "pedit.err.sni", advanced: true) }
        if !isIPv4CIDR(tun) { return Problem(key: "pedit.err.tun", advanced: true) }
        return nil
    }

    /// `host:port`, IPv6 — в квадратных скобках.
    static func isHostPort(_ s: String) -> Bool {
        guard let colon = s.lastIndex(of: ":"),
              let port = Int(s[s.index(after: colon)...]), (1...65_535).contains(port),
              s[s.index(after: colon)...].allSatisfy(\.isASCIIDigit)
        else { return false }
        return isHost(String(s[..<colon]))
    }

    static func isHost(_ s: String) -> Bool {
        if s.hasPrefix("[") && s.hasSuffix("]") {
            return s.count > 2 && s.dropFirst().dropLast().allSatisfy { $0.isHexDigit || $0 == ":" }
        }
        return isDomain(s)
    }

    /// Домен или IPv4 без порта.
    static func isDomain(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.hasPrefix("-")
            && s.allSatisfy { $0.isLetter || $0.isASCIIDigit || $0 == "." || $0 == "-" }
    }

    /// `a.b.c.d/n`.
    static func isIPv4CIDR(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isNumber(parts[1], max: 32) else { return false }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets.allSatisfy { isNumber($0, max: 255) }
    }

    private static func isNumber(_ s: Substring, max: Int) -> Bool {
        (1...3).contains(s.count) && s.allSatisfy(\.isASCIIDigit) && Int(s)! <= max
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
