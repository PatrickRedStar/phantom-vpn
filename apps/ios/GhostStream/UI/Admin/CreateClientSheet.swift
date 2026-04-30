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
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        fieldLabel(L("admin.add.name.hint"))
                        TextField("alice", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body)
                            .padding(12)
                            .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    NativeSectionCard {
                        Toggle(isOn: $perpetual) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("admin.subscription.perpetual"))
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(C.bone)
                                Text(L("admin.add.days.hint"))
                                    .font(.footnote)
                                    .foregroundColor(C.textDim)
                            }
                        }
                        .tint(C.signal)

                        if !perpetual {
                            HairlineDivider()
                            TextField(L("admin.sub.days.hint"), text: $expiresDaysText)
                                .keyboardType(.numberPad)
                                .font(.body.monospacedDigit())
                                .padding(.vertical, 12)
                        }
                    }

                    NativeSectionCard {
                        Toggle(isOn: $isAdmin) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L("admin.client.is.admin"))
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(C.bone)
                                Text(L("admin.client.is.admin.subtitle"))
                                    .font(.footnote)
                                    .foregroundColor(C.textDim)
                            }
                        }
                        .tint(C.signal)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(C.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(18)
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(L("admin.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("general.cancel")) {
                        dismiss()
                    }
                    .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if submitting {
                            ProgressView()
                        } else {
                            Text(L("admin.action.create"))
                        }
                    }
                    .disabled(!canSubmit || submitting)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundColor(C.textDim)
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
