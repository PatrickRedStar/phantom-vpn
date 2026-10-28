import Foundation

public enum MacStartupForegroundWindow: String, Equatable {
    case welcome
    case console
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

/// Что показать при запуске macOS-приложения (только macOS).
public enum MacStartupPolicy {
    /// - Parameters:
    ///   - startInMenuBar: «Запускать в строке меню» — без окна.
    ///   - launchedAtLogin: запущено как объект входа — тоже без консоли.
    public static func decide(
        managerConfigured: Bool,
        hasActiveProfile: Bool,
        startInMenuBar: Bool,
        launchedAtLogin: Bool = false
    ) -> MacStartupDecision {
        if managerConfigured {
            return MacStartupDecision(
                shouldActivateSystemExtension: true,
                foregroundWindow: startInMenuBar || launchedAtLogin ? nil : .console
            )
        }

        return MacStartupDecision(
            shouldActivateSystemExtension: hasActiveProfile,
            foregroundWindow: startInMenuBar ? nil : .welcome
        )
    }
}
