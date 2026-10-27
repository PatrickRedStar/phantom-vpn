// VpnActions — Connect / Disconnect for App Intents (Shortcuts, widget,
// Control Center, Live Activity). Same path as the Dashboard buttons:
// active profile → VpnTunnelController.installAndStart, state through
// VpnStateManager.

import Foundation
import PhantomKit

enum VpnActionError: Error, CustomLocalizedStringResourceConvertible {
    case noProfile

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource("intent.error.no.profile", table: "Widgets")
    }
}

@MainActor
enum VpnActions {

    static func connect() async throws {
        let tunnel = VpnTunnelController()
        switch await tunnel.currentStatus() {
        case .connected, .connecting, .reasserting: return
        default: break
        }
        guard let profile = ProfilesStore.shared.activeProfile,
              profile.certPem?.isEmpty == false,
              profile.keyPem?.isEmpty == false
        else { throw VpnActionError.noProfile }

        VpnStateManager.shared.update(.connecting)
        do {
            try await tunnel.installAndStart(profile: profile, preferences: .shared)
        } catch {
            VpnStateManager.shared.update(.error(ConnectErrorHumanizer.humanize(
                error.localizedDescription,
                english: AppStrings.isEnglish
            )))
            throw error
        }

        // Stay in the intent until the tunnel settles: the app may be in the
        // background only for the intent's lifetime, and the Live Activity
        // can be started only while it runs. Then the control reloads with
        // the real state.
        for _ in 0..<60 {
            switch VpnStateManager.shared.state {
            case .connecting: try? await Task.sleep(nanoseconds: 250_000_000)
            default: return
            }
        }
    }

    static func disconnect() async {
        VpnStateManager.shared.update(.disconnecting)
        await VpnTunnelController().stopAndWait()
    }
}
