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

    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "LoginItem")

    private init() {
        refresh()
    }

    public func refresh() {
        enabled = (SMAppService.mainApp.status == .enabled)
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
        }
    }
}
