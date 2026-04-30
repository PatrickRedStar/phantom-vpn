//
//  CreateClientSheet.swift
//  GhostStream
//

import PhantomUI
import SwiftUI

/// Bottom-sheet form for creating a new admin-managed client.
public struct CreateClientSheet: View {

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss

    let viewModel: AdminViewModel

    @State private var name = ""
    @State private var expiresDaysText = "30"
    @State private var isAdmin = false
    @State private var perpetual = false
    @State private var submitting = false
    @State private var errorMessage: String?

    public init(viewModel: AdminViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ZStack {
            C.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("admin.add.title").uppercased())
                        .gsFont(.labelMono)
                        .foregroundColor(C.bone)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("×")
                            .gsFont(.valueMono)
                            .foregroundColor(C.textDim)
                    }
                    .buttonStyle(.plain)
                    .disabled(submitting)
                }

                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel(L("admin.add.name.hint"))
                    GhostTextField("alice", text: $name)
                }

                VStack(alignment: .leading, spacing: 10) {
                    fieldLabel(L("admin.subscription.perpetual"))
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("admin.add.days.hint"))
                                .gsFont(.body)
                                .foregroundColor(C.textDim)
                        }
                        Spacer()
                        GhostToggle(isOn: $perpetual, onLabel: L("admin.subscription.perpetual"))
                    }
                    if !perpetual {
                        GhostTextField(L("admin.sub.days.hint"), text: $expiresDaysText, keyboardType: .numberPad)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ADMIN")
                            .gsFont(.labelMono)
                            .foregroundColor(C.textFaint)
                        Text("is_admin")
                            .gsFont(.body)
                            .foregroundColor(C.textDim)
                    }
                    Spacer()
                    GhostToggle(isOn: $isAdmin, onLabel: "Admin")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .gsFont(.body)
                        .foregroundColor(C.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    GhostButton(L("general.cancel"), variant: .secondary) { dismiss() }
                        .disabled(submitting)
                    GhostButton(L("admin.action.create"), isEnabled: canSubmit && !submitting) {
                        Task { await submit() }
                    }
                }
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
            .padding(18)

            if submitting {
                Color.black.opacity(0.25).ignoresSafeArea()
                ProgressView().tint(C.signal)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .gsFont(.labelMonoSmall)
            .foregroundColor(C.textFaint)
    }

    private var canSubmit: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if perpetual { return true }
        guard let n = Int(expiresDaysText), n > 0 else { return false }
        return true
    }

    private func submit() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let days: Int? = perpetual ? nil : Int(expiresDaysText)
        submitting = true
        errorMessage = nil
        defer { submitting = false }
        do {
            try await viewModel.createClient(name: trimmed, expiresDays: days, isAdmin: isAdmin)
            dismiss()
        } catch let err as AdminHttpError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview("CreateClientSheet") {
    CreateClientSheet(viewModel: AdminPreviewData.populatedVM())
        .gsTheme(override: .dark)
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
