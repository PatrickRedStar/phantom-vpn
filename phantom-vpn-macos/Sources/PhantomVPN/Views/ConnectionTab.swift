import SwiftUI

struct ConnectionTab: View {
    @EnvironmentObject var vpnManager: VpnManager
    @EnvironmentObject var profileStore: ProfileStore

    var body: some View {
        VStack(spacing: 0) {
            // Status ring
            statusRing
                .padding(.top, 24)
                .padding(.bottom, 8)

            Text(vpnManager.state.label)
                .font(.headline)

            if let since = vpnManager.connectedSince {
                Text("с \(since.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 20)

            // Profile info
            if let profile = profileStore.activeProfile {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(profile.name, systemImage: "person.badge.key")
                            .font(.subheadline)
                        Text(profile.serverAddr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(profile.tunAddr)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
            } else {
                Text("Нет профилей. Перейдите во вкладку «Профили».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer().frame(height: 20)

            // Connect / Disconnect button
            Button(action: toggleVPN) {
                HStack(spacing: 8) {
                    if case .connecting = vpnManager.state {
                        ProgressView().scaleEffect(0.7).frame(width: 16, height: 16)
                    }
                    Text(buttonLabel)
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(buttonTint)
            .disabled(profileStore.activeProfile == nil || isButtonDisabled)
            .padding(.horizontal, 16)

            Spacer().frame(height: 20)

            // Error detail
            if case .error(let msg) = vpnManager.state {
                GroupBox {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            // Quit row
            HStack {
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(minHeight: 340)
    }

    private var statusRing: some View {
        ZStack {
            Circle()
                .fill(ringColor.opacity(0.12))
                .frame(width: 90, height: 90)
            Circle()
                .fill(ringColor.opacity(0.25))
                .frame(width: 68, height: 68)
            Image(systemName: statusIcon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(ringColor)
        }
        .animation(.easeInOut(duration: 0.25), value: vpnManager.state)
    }

    private var statusIcon: String {
        switch vpnManager.state {
        case .disconnected: return "shield"
        case .connecting:   return "shield.lefthalf.filled"
        case .connected:    return "shield.fill"
        case .error:        return "exclamationmark.shield.fill"
        }
    }

    private var ringColor: Color {
        switch vpnManager.state {
        case .disconnected: return .secondary
        case .connecting:   return .orange
        case .connected:    return .green
        case .error:        return .red
        }
    }

    private var buttonLabel: String {
        switch vpnManager.state {
        case .disconnected: return "Подключить"
        case .connecting:   return "Подключение…"
        case .connected:    return "Отключить"
        case .error:        return "Повторить"
        }
    }

    private var buttonTint: Color {
        switch vpnManager.state {
        case .connected: return .red
        case .error:     return .orange
        default:         return .accentColor
        }
    }

    private var isButtonDisabled: Bool {
        if case .connecting = vpnManager.state { return true }
        return false
    }

    private func toggleVPN() {
        switch vpnManager.state {
        case .disconnected, .error:
            if let p = profileStore.activeProfile { vpnManager.connect(profile: p) }
        case .connected, .connecting:
            vpnManager.disconnect()
        }
    }
}
