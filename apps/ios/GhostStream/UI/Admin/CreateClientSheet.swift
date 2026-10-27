//
//  CreateClientSheet.swift
//  GhostStream
//

import PhantomKit
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
    /// Set once the client exists — the sheet then shows its link as QR.
    @State private var created = false
    @State private var connString: String?

    public init(viewModel: AdminViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                if created {
                    VStack(alignment: .leading, spacing: 12) {
                        if let connString {
                            ConnStringShareCard(connString: connString)
                        }
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.custom(GsFontName.jetBrainsMono, size: 11))
                                .foregroundColor(C.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(18)
                } else {
                    form
                }
            }
            .background(C.bg.ignoresSafeArea())
            .navigationTitle(created ? name.trimmingCharacters(in: .whitespacesAndNewlines) : L("admin.add.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Icon buttons, as in the other sheets: text pills squeezed
                // the title to «Новый к…» at large text sizes.
                if created {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Label(L("admin.add.done"), systemImage: "checkmark")
                        }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Label(L("general.cancel"), systemImage: "xmark")
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
                                Label(L("admin.action.create"), systemImage: "checkmark")
                            }
                        }
                        .disabled(!canSubmit || submitting)
                    }
                }
            }
        }
        .presentationDetents(created ? [.medium] : [.medium, .large])
        .interactiveDismissDisabled(submitting)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                fieldLabel(L("admin.add.name.hint"))
                TextField("alice", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.custom(GsFontName.jetBrainsMono, size: 15))
                    .padding(12)
                    .background(C.bgElev2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            NativeSectionCard {
                NativeToggleRow(
                    title: L("admin.subscription.perpetual"),
                    subtitle: L("admin.add.days.hint"),
                    isOn: $perpetual
                )

                if !perpetual {
                    HairlineDivider()
                    TextField(L("admin.sub.days.hint"), text: $expiresDaysText)
                        .keyboardType(.numberPad)
                        .font(.custom(GsFontName.jetBrainsMono, size: 13))
                        .padding(.vertical, 12)
                }
            }

            NativeSectionCard {
                NativeToggleRow(
                    title: L("admin.client.is.admin"),
                    subtitle: L("admin.client.is.admin.subtitle"),
                    isOn: $isAdmin
                )
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.custom(GsFontName.jetBrainsMono, size: 11))
                    .foregroundColor(C.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.custom(GsFontName.jetBrainsMono, size: 10))
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
        } catch let err as AdminHttpError {
            errorMessage = err.errorDescription
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        // Created — hand the link over right here (as macOS does).
        created = true
        do {
            connString = try await viewModel.getConnString(name: trimmed)
        } catch let err as AdminHttpError {
            errorMessage = err.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#if DEBUG
#Preview("CreateClientSheet") {
    CreateClientSheet(viewModel: AdminPreviewData.populatedVM())
        .gsTheme(override: .dark)
}
#endif

private func L(_ key: String) -> String {
    AppStrings.localized(key)
}
