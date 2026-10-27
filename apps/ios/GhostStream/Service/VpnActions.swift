// VpnActions — Connect / Disconnect for App Intents (Shortcuts, widget,
// Control Center, Live Activity). Same path as the Dashboard buttons:
// active profile → VpnTunnelController.installAndStart, state through
// VpnStateManager.

import Foundation
import PhantomKit
import UIKit

enum VpnActionError: Error, CustomLocalizedStringResourceConvertible {
    case noProfile
    /// No VPN configuration yet: its first save shows the system prompt,
    /// which an intent running in the background can't present.
    case needsSetup
    /// Connect failed; the text is already humanized in the app's language.
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noProfile: return LocalizedStringResource("intent.error.no.profile", table: "Widgets")
        case .needsSetup: return LocalizedStringResource("intent.error.needs.setup", table: "Widgets")
        case .failed(let message): return "\(message)"
        }
    }
}

@MainActor
enum VpnActions {

    static func connect() async throws {
        // A manual Connect lifts the fatal-stop guard (ADR 0018) — also when
        // On-Demand is already retrying and the early return below hits.
        UserDefaults(suiteName: SharedKeys.appGroup)?.removeObject(forKey: SharedKeys.fatalStop)
        let tunnel = VpnTunnelController()
        switch await tunnel.currentStatus() {
        case .connected, .connecting, .reasserting: return
        default: break
        }
        guard let profile = ProfilesStore.shared.activeProfile,
              profile.certPem?.isEmpty == false,
              profile.keyPem?.isEmpty == false
        else { throw VpnActionError.noProfile }
        if tunnel.manager?.protocolConfiguration == nil,
           UIApplication.shared.applicationState != .active {
            throw VpnActionError.needsSetup
        }

        VpnStateManager.shared.update(.connecting)
        do {
            try await tunnel.installAndStart(profile: profile, preferences: .shared)
        } catch {
            let message = ConnectErrorHumanizer.humanize(
                error.localizedDescription,
                english: AppStrings.isEnglish
            )
            VpnStateManager.shared.update(.error(message))
            throw VpnActionError.failed(message)
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
        let tunnel = VpnTunnelController()
        switch await tunnel.currentStatus() {
        case .disconnected, .invalid:
            // Nothing will report "disconnected" back: don't leave
            // «Отключение» behind, and keep a fatal reason on screen.
            if case .error = VpnStateManager.shared.state {} else {
                VpnStateManager.shared.update(.disconnected)
            }
        default:
            VpnStateManager.shared.update(.disconnecting)
        }
        // Also turns On-Demand off, so iOS doesn't bring the tunnel back.
        await tunnel.stopAndWait()
        // The app may be suspended before the tunnel reports "disconnected".
        await SystemSurfaces.shared.endLiveActivity()
    }
}
