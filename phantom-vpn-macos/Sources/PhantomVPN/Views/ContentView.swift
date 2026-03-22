import SwiftUI

struct ContentView: View {
    @EnvironmentObject var vpnManager: VpnManager
    @EnvironmentObject var profileStore: ProfileStore
    @EnvironmentObject var adminManager: AdminManager
    @State private var selectedTab = 0

    // Configure admin manager from active profile
    private func syncAdminManager() {
        if let p = profileStore.activeProfile, let url = p.adminUrl, let tok = p.adminToken {
            adminManager.configure(adminUrl: url, adminToken: tok)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("", selection: $selectedTab) {
                Label("VPN", systemImage: "shield").tag(0)
                Label("Профили", systemImage: "person.2").tag(1)
                if adminManager.isConfigured {
                    Label("Админ", systemImage: "gearshape.2").tag(2)
                }
                Label("Логи", systemImage: "doc.text").tag(3)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            Group {
                switch selectedTab {
                case 0: ConnectionTab()
                case 1: ProfilesTab()
                case 2: AdminPanelView()
                case 3: LogsTab()
                default: EmptyView()
                }
            }
        }
        .onAppear {
            syncAdminManager()
        }
        .onChange(of: profileStore.activeProfileId) { _, _ in
            syncAdminManager()
        }
    }
}
