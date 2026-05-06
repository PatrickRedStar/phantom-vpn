import Foundation

public enum MacStartupForegroundWindow: String, Equatable {
    case welcome
}

public struct MacStartupDecision: Equatable {
    public let shouldActivateSystemExtension: Bool
    public let foregroundWindow: MacStartupForegroundWindow?

    public init(
        shouldActivateSystemExtension: Bool,
        foregroundWindow: MacStartupForegroundWindow?
    ) {
        self.shouldActivateSystemExtension = shouldActivateSystemExtension
        self.foregroundWindow = foregroundWindow
    }
}

public enum MacStartupPolicy {
    public static func decide(
        managerConfigured: Bool,
        hasActiveProfile: Bool,
        startInMenuBar: Bool
    ) -> MacStartupDecision {
        if managerConfigured {
            return MacStartupDecision(
                shouldActivateSystemExtension: true,
                foregroundWindow: nil
            )
        }

        return MacStartupDecision(
            shouldActivateSystemExtension: hasActiveProfile,
            foregroundWindow: startInMenuBar ? nil : .welcome
        )
    }
}
