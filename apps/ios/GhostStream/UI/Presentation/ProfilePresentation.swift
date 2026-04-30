import Foundation
import PhantomKit

enum ProfileActionKind: Hashable {
    case serverControl
    case createClientLink
    case identity
    case subscription
    case setActive
    case edit
    case share
    case delete
}

enum ProfilePresentation {
    static func actions(for profile: VpnProfile, isActive: Bool) -> [ProfileActionKind] {
        var actions: [ProfileActionKind] = []

        if profile.cachedIsAdmin == true {
            actions.append(.serverControl)
            actions.append(.createClientLink)
        }

        actions.append(.identity)
        actions.append(.subscription)

        if !isActive {
            actions.append(.setActive)
        }

        actions.append(.edit)
        actions.append(.share)
        actions.append(.delete)

        return actions
    }
}
