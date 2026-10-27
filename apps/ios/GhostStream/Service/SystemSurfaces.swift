// SystemSurfaces — keeps the home-screen widget and the Control Center
// toggle in step with VpnStateManager. Called on every state notification
// (VpnStateManager's Darwin observer).

import Foundation
import PhantomKit
import WidgetKit

@MainActor
final class SystemSurfaces {
    static let shared = SystemSurfaces()

    private var lastKind: VpnStatePayload.Kind?

    func sync() {
        let kind = VpnStatePayload.from(VpnStateManager.shared.state).kind
        guard kind != lastKind else { return }
        lastKind = kind
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
    }
}
