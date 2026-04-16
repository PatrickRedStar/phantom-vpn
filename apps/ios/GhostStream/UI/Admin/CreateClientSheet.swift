//
//  CreateClientSheet.swift
//  GhostStream
//
//  Modal form presented from AdminView's "CREATE CLIENT" CTA.
//  Collects name / expires-days / is-admin, posts via AdminViewModel.
//

import SwiftUI

/// Bottom-sheet form for creating a new admin-managed client.
///
/// On "Создать" taps `AdminViewModel.createClient(...)`; on success dismisses
/// the sheet and the parent's refreshed client list shows the new row.
public struct CreateClientSheet: View {

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss

    /// Shared VM — we call `createClient` on it and rely on its own refresh.
    let viewModel: AdminViewModel

    @State private var name: String = ""
    @State private var expiresDaysText: String = "30"
    @State private var isAdmin: Bool = false
    @State private var perpetual: Bool = false
    @State private var submitting: Bool = false
    @State private var errorMessage: String?

    public init(viewModel: AdminViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("например alice", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("ИМЯ КЛИЕНТА")
                        .gsFont(.labelMono)
                        .foregroundColor(C.textDim)
                }

                Section {
                    Toggle("Бессрочная подписка", isOn: $perpetual)
                    if !perpetual {
                        TextField("дни", text: $expiresDaysText)
                            .keyboardType(.numberPad)
                    }
                } header: {
                    Text("ПОДПИСКА")
                        .gsFont(.labelMono)
                        .foregroundColor(C.textDim)
                } footer: {
                    Text("Бессрочная = без expires_at на сервере.")
                        .gsFont(.body)
                        .foregroundColor(C.textFaint)
                }

                Section {
                    Toggle("Админ (is_admin)", isOn: $isAdmin)
                        .tint(C.warn)
                } footer: {
                    Text("Админ может управлять всеми клиентами через Admin API.")
                        .gsFont(.body)
                        .foregroundColor(C.textFaint)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .gsFont(.body)
                            .foregroundColor(C.danger)
                    }
                }
            }
            .navigationTitle("Новый клиент")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                        .disabled(submitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Создать") {
                        Task { await submit() }
                    }
                    .disabled(!canSubmit || submitting)
                }
            }
            .overlay {
                if submitting {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView().tint(C.signal)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Validation & submission

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
            try await viewModel.createClient(
                name: trimmed,
                expiresDays: days,
                isAdmin: isAdmin
            )
            dismiss()
        } catch let err as AdminHttpError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Previews

#Preview("CreateClientSheet") {
    CreateClientSheet(viewModel: AdminPreviewData.populatedVM())
        .gsTheme(override: .dark)
}
