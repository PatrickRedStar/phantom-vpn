//
//  AdminCreateClientSheet.swift
//  GhostStream (macOS)
//
//  "New client" modal for the ADMIN tab. Creates a client on the server
//  (cert + key are generated server-side), then shows the resulting ghs://
//  connection string exactly once with a copy button — the secret is not
//  retained by the UI after the sheet closes.
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
    @State private var durationDays: Int? = 30   // nil = perpetual
    @State private var isAdmin = false
    @State private var submitting = false
    @State private var errorText: String?
    @State private var resultGhs: String?

    private static let durations: [(label: String, days: Int?)] = [
        ("7", 7), ("30", 30), ("90", 90), ("∞", nil)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(resultGhs == nil ? L("admin.create.title") : L("admin.create.done.title"))
                .font(.custom("SpaceGrotesk-Bold", size: 19))
                .foregroundStyle(C.bone)
                .padding(.bottom, 18)

            if let resultGhs {
                resultBlock(resultGhs)
            } else {
                form
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(RoundedRectangle(cornerRadius: GsRadius.window, style: .continuous).fill(C.bgElev))
    }

    // MARK: - Form

    @ViewBuilder
    private var form: some View {
        fieldLabel(L("admin.create.name"))
        TextField("plankton", text: $name)
            .textFieldStyle(.plain)
            .font(.custom("JetBrainsMono-Regular", size: 12))
            .foregroundStyle(C.bone)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(C.bg))
            .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.hair, lineWidth: 1))

        fieldLabel(L("admin.create.duration"))
        HStack(spacing: 0) {
            ForEach(Self.durations, id: \.label) { option in
                let selected = durationDays == option.days
                Button {
                    durationDays = option.days
                } label: {
                    Text(option.days.map { "\($0) \(L("admin.create.days"))" } ?? L("admin.create.perpetual"))
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .tracking(0.12 * 9.5)
                        .foregroundStyle(selected ? C.signal : C.textDim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(selected ? C.bgElev2 : Color.clear)
                        .contentShape(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.hair, lineWidth: 1))

        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("admin.create.admin_toggle"))
                    .font(.custom("JetBrainsMono-Regular", size: 12))
                    .foregroundStyle(C.bone)
                Text(L("admin.create.admin_desc"))
                    .font(.custom("JetBrainsMono-Regular", size: 10))
                    .foregroundStyle(C.textFaint)
            }
            Spacer()
            Toggle("", isOn: $isAdmin)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(C.signal)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(C.hair).frame(height: 1)
        }

        if let errorText {
            Text(errorText)
                .font(.custom("JetBrainsMono-Regular", size: 10.5))
                .foregroundStyle(C.danger)
                .padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
            bigButton(
                submitting ? "…" : L("admin.create.submit"),
                prominent: true,
                disabled: trimmedName.isEmpty || submitting
            ) {
                submit()
            }
            bigButton(L("general.cancel"), prominent: false, disabled: submitting) {
                dismiss()
            }
        }
        .padding(.top, 16)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Result (shown once)

    @ViewBuilder
    private func resultBlock(_ ghs: String) -> some View {
        fieldLabel(L("admin.create.result"))
        ScrollView {
            Text(ghs)
                .font(.custom("JetBrainsMono-Regular", size: 10))
                .foregroundStyle(C.signal)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 120)
        .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(C.bg))
        .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(C.signalDim, lineWidth: 1))

        HStack(spacing: 8) {
            bigButton(L("admin.create.copy"), prominent: true, disabled: false) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ghs, forType: .string)
                onStatus(L("admin.status.ghs_copied"), true)
            }
            bigButton(L("general.done"), prominent: false, disabled: false) {
                dismiss()
            }
        }
        .padding(.top, 16)
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

    private func bigButton(
        _ title: String,
        prominent: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("DepartureMono-Regular", size: 10.5))
                .tracking(0.16 * 10.5)
                .foregroundStyle(prominent ? C.bg : C.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).fill(prominent ? C.signal : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous).stroke(prominent ? C.signal : C.hairBold, lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: GsRadius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
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
                try await vm.createClient(
                    name: clientName,
                    expiresDays: durationDays,
                    isAdmin: isAdmin
                )
                // The POST response is not retained by the VM — fetch the
                // conn string explicitly so it can be handed out once.
                let ghs = try await vm.getConnString(name: clientName)
                resultGhs = ghs
                onStatus(String(format: L("admin.status.created"), clientName), true)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
