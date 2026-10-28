//
//  LoginItemController.swift
//  GhostStream (macOS)
//
//  Wraps `SMAppService.mainApp` to enable / disable launch-at-login.
//

import Foundation
import Observation
import ServiceManagement
import os.log

@MainActor
@Observable
public final class LoginItemController {

    public static let shared = LoginItemController()

    public private(set) var enabled: Bool = false
    /// Зарегистрирован, но пользователь ещё не разрешил (или выключил) его
    /// в «Системные настройки → Основные → Объекты входа и расширения».
    public private(set) var requiresApproval: Bool = false

    private let log = Logger(subsystem: "com.ghoststream.client", category: "LoginItem")

    private init() {
        refresh()
    }

    public func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    public func setEnabled(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
            refresh()
        }
    }
}
