import SwiftUI

@main
struct PhantomVPNApp: App {
    @StateObject private var profileStore = ProfileStore.shared
    @StateObject private var preferences = PreferencesStore.shared
    @StateObject private var vpnManager = VpnManager.shared
    @StateObject private var adminManager = AdminManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(profileStore)
                .environmentObject(preferences)
                .environmentObject(vpnManager)
                .environmentObject(adminManager)
                .preferredColorScheme(preferences.colorScheme)
                .onAppear {
                    vpnManager.bootstrapManager()
                    syncAdmin()
                }
                .onChange(of: profileStore.activeProfileId) { _, _ in
                    syncAdmin()
                }
        }
    }

    private func syncAdmin() {
        guard let p = profileStore.activeProfile,
              let url = p.adminUrl,
              let token = p.adminToken else {
            adminManager.clearConfiguration()
            return
        }
        adminManager.configure(adminUrl: url, adminToken: token)
    }
}
