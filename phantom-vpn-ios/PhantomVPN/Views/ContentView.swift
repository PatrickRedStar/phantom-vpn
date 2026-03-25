import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var adminManager: AdminManager

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Главная", systemImage: "shield.lefthalf.filled")
                }

            LogsView()
                .tabItem {
                    Label("Логи", systemImage: "terminal")
                }

            SettingsView()
                .tabItem {
                    Label("Настройки", systemImage: "gearshape.fill")
                }
        }
        .onChange(of: profileStore.activeProfileId) { _ in
            if adminManager.isConfigured {
                adminManager.refresh()
            }
        }
    }
}
