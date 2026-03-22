import SwiftUI
import AppKit

@main
struct PhantomVPNApp: App {
    @StateObject private var vpnManager = VpnManager.shared
    @StateObject private var profileStore = ProfileStore.shared
    @StateObject private var adminManager = AdminManager.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(vpnManager)
                .environmentObject(profileStore)
                .environmentObject(adminManager)
                .frame(width: 400)
        } label: {
            MenuBarIcon(state: vpnManager.state)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    let state: VpnState
    var body: some View {
        switch state {
        case .connected:
            Image(systemName: "shield.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.green, .primary)
        case .connecting:
            Image(systemName: "shield.lefthalf.filled")
        case .error:
            Image(systemName: "exclamationmark.shield.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red, .primary)
        case .disconnected:
            Image(systemName: "shield")
        }
    }
}
