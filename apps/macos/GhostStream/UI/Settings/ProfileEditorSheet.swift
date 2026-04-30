//
//  ProfileEditorSheet.swift
//  GhostStream (macOS)
//
//  CRUD профилей: paste new ghs:// + name + delete.
//

import PhantomKit
import PhantomUI
import SwiftUI

public struct ProfileEditorSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles

    @State private var newGhs: String = ""
    @State private var newName: String = ""
    @State private var importError: String?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("PROFILES")
                    .font(Typography.labelMono)
                    .tracking(0.2 * 10.5)
                    .foregroundStyle(C.textFaint)
                Spacer()
                Button("Закрыть") { dismiss() }
            }

            HairlineDivider()

            if profiles.profiles.isEmpty {
                Text(String(localized: "roster.empty"))
                    .font(Typography.body)
                    .foregroundStyle(C.textFaint)
                    .padding(.vertical, 16)
            } else {
                List {
                    ForEach(profiles.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(Typography.profileName).foregroundStyle(C.bone)
                                Text(profile.serverAddr).font(Typography.host).foregroundStyle(C.textFaint)
                            }
                            Spacer()
                            Button("Удалить", role: .destructive) {
                                profiles.remove(id: profile.id)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(C.danger)
                        }
                        .padding(.vertical, 6)
                    }
                }
                .frame(minHeight: 160)
            }

            Text("ADD NEW")
                .font(Typography.labelMonoTiny)
                .foregroundStyle(C.textFaint)

            TextField("Имя", text: $newName)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .padding(10)
                .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))

            TextField("ghs://...", text: $newGhs, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.custom("JetBrainsMono-Regular", size: 12))
                .lineLimit(4, reservesSpace: true)
                .padding(10)
                .overlay(Rectangle().stroke(C.hairBold, lineWidth: 1))

            if let err = importError {
                Text(err)
                    .font(Typography.bodySmall)
                    .foregroundStyle(C.danger)
            }

            HStack {
                Spacer()
                Button {
                    importProfile()
                } label: {
                    Text("ИМПОРТИРОВАТЬ")
                        .font(Typography.labelMono)
                        .tracking(0.18 * 10.5)
                        .foregroundStyle(C.signal)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .overlay(Rectangle().stroke(C.signal, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(newGhs.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 520)
        .background(C.bg)
    }

    private func importProfile() {
        do {
            let trimmed = newGhs.trimmingCharacters(in: .whitespacesAndNewlines)
            var profile = try profiles.importFromConnString(trimmed)
            if !newName.isEmpty {
                profile.name = newName
                profiles.update(profile)
            }
            newGhs = ""
            newName = ""
            importError = nil
        } catch {
            importError = "Неверная ghs:// строка"
        }
    }
}
