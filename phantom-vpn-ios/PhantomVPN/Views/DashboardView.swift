import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var vpnManager: VpnManager
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var preferences: PreferencesStore

    private var stateLabel: String {
        switch vpnManager.state {
        case .disconnected: return "Отключено"
        case .connecting: return "Подключение..."
        case .connected: return "Подключено"
        case .disconnecting: return "Отключение..."
        case .error(let message): return "Ошибка: \(message)"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectButton(state: vpnManager.state) {
                        onConnectToggle()
                    }
                    .padding(.top, 24)

                    Text(stateLabel)
                        .font(.headline)
                        .foregroundStyle(vpnManager.stats.connected ? Color.greenConnected : .secondary)

                    Text(vpnManager.timerText)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)

                    if let warning = vpnManager.preflightWarning {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Предупреждение")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text(warning)
                                .font(.footnote)
                            Button("Повторить") {
                                vpnManager.dismissPreflightWarning()
                                onConnectToggle()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.yellowWarning.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatCard(title: "Download", value: FormatUtils.formatBytes(vpnManager.stats.bytes_rx), icon: "arrow.down")
                        StatCard(title: "Upload", value: FormatUtils.formatBytes(vpnManager.stats.bytes_tx), icon: "arrow.up")
                        StatCard(title: "Packets RX", value: "\(vpnManager.stats.pkts_rx)", icon: "arrow.down.right.circle")
                        StatCard(title: "Packets TX", value: "\(vpnManager.stats.pkts_tx)", icon: "arrow.up.right.circle")
                    }

                    if let profile = profileStore.activeProfile, let exp = profile.cachedExpiresAt {
                        let seconds = exp - Int64(Date().timeIntervalSince1970)
                        let days = max(0, seconds / 86400)
                        Text("Подписка: \(days) дн.")
                            .font(.subheadline)
                            .foregroundStyle(days <= 3 ? Color.redError : .secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("GhostStream")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: switchThemeMode) {
                        switch preferences.themeMode {
                        case "dark":
                            Image(systemName: "moon.fill")
                        case "light":
                            Image(systemName: "sun.max.fill")
                        default:
                            Text("A")
                                .font(.body)
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    private func switchThemeMode() {
        switch preferences.themeMode {
        case "system":
            preferences.themeMode = "dark"
        case "dark":
            preferences.themeMode = "light"
        default:
            preferences.themeMode = "system"
        }
    }

    private func onConnectToggle() {
        switch vpnManager.state {
        case .connected, .connecting:
            vpnManager.disconnect()
        default:
            let cfg = preferences.mergedConfig(profile: profileStore.activeProfile)
            vpnManager.connect(config: cfg)
        }
    }
}
