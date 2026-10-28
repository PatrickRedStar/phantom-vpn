//
//  AdminCreateClientSheet.swift
//  GhostStream (macOS)
//
//  «Новый клиент»: имя, срок, права. Серт и ключ сервер выпускает сам;
//  ghs://-ссылка с QR показывается один раз и после закрытия не хранится.
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

struct AdminCreateClientSheet: View {

    let vm: AdminViewModel
    let onStatus: (String, Bool) -> Void

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// 0 — бессрочно (так и уходит на сервер).
    @State private var days = 30
    @State private var isAdmin = false
    @State private var submitting = false
    @State private var errorText: String?
    @State private var resultLink: String?

    var body: some View {
        VStack(spacing: 0) {
            if let resultLink {
                result(resultLink)
            } else {
                form
            }
            buttons
        }
        .frame(width: 460)
        .background(C.bg)
    }

    // MARK: - Form

    private var form: some View {
        Form {
            Section(L("adm.new")) {
                TextField(text: $name, prompt: Text(L("adm.create.name.prompt"))) {
                    Text(L("adm.create.name"))
                }
                Picker(L("adm.create.duration"), selection: $days) {
                    ForEach([7, 30, 90], id: \.self) { d in
                        Text(String(format: L("adm.create.days"), Int32(d))).tag(d)
                    }
                    Text(L("adm.create.forever")).tag(0)
                }
                Toggle(isOn: $isAdmin) {
                    Text(L("adm.create.admin"))
                    Text(L("adm.create.admin.hint"))
                }
                .tint(C.signal)
            }
            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(C.danger)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(height: errorText == nil ? 200 : 260)
    }

    // MARK: - Result (shown once)

    private func result(_ link: String) -> some View {
        VStack(spacing: GsSpace.m) {
            Text(String(format: L("adm.create.done"), trimmedName))
                .gsType(.headline)
                .foregroundStyle(C.bone)
            Text(L("adm.create.done.hint"))
                .gsType(.caption)
                .foregroundStyle(C.textDim)
                .multilineTextAlignment(.center)
            QRCodeView(link: link)
            Text(link)
                .font(.custom(GsFontName.jetBrainsMono, size: 10))
                .foregroundStyle(C.textDim)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(GsSpace.xl)
    }

    private var buttons: some View {
        HStack(spacing: GsSpace.s) {
            Spacer()
            if let resultLink {
                Button(L("adm.copy_link")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(resultLink, forType: .string)
                    onStatus(L("adm.copied"), true)
                }
                .controlSize(.large)
                .gsGlassButton()
                primary(L("general.done")) { dismiss() }
            } else {
                Button(L("general.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .gsGlassButton()
                    .disabled(submitting)
                primary(L("adm.create.submit"), action: submit)
                    .disabled(trimmedName.isEmpty || submitting)
            }
        }
        .padding(.horizontal, GsSpace.xl)
        .padding(.bottom, GsSpace.xl)
    }

    private func primary(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(C.bg)
                .padding(.horizontal, GsSpace.xs)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .gsProminentButton(tint: C.signal)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Submit

    private func submit() {
        let clientName = trimmedName
        guard !clientName.isEmpty else { return }
        submitting = true
        errorText = nil
        Task {
            defer { submitting = false }
            do {
                try await vm.createClient(name: clientName, expiresDays: days == 0 ? nil : days, isAdmin: isAdmin)
                // Ответ POST VM не хранит — ссылку берём отдельным запросом.
                resultLink = try await vm.getConnString(name: clientName)
                onStatus(String(format: L("adm.create.done"), clientName), true)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
