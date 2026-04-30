//
//  SystemExtensionInstaller.swift
//  GhostStream (macOS)
//
//  Wraps `OSSystemExtensionRequest` activation lifecycle and surfaces a
//  state machine consumed by the WelcomeWindow / installer banner.
//
//  Flow:
//    NotInstalled
//      → submitActivationRequest()
//      → AwaitingUserApproval (user must Allow in System Settings)
//      → Activated
//      → ManagerConfigured (after VpnTunnelController installs the manager)
//      → Ready
//

import Foundation
import Observation
import SystemExtensions
import os.log

@MainActor
@Observable
public final class SystemExtensionInstaller: NSObject {

    public static let shared = SystemExtensionInstaller()

    public enum State: Equatable {
        case notInstalled
        case requestPending
        case awaitingUserApproval
        case activated
        case failed(String)
    }

    public private(set) var state: State
    public private(set) var lastMessage: String?

    /// Bundle id of the system extension target (must match
    /// PacketTunnelExtension/Info.plist CFBundleIdentifier).
    public let extensionBundleId = "com.ghoststream.vpn.tunnel"

    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "SystemExtensionInstaller")
    private enum PendingAction { case activation, deactivation }
    private var pendingAction: PendingAction?
    private var pendingRequest: OSSystemExtensionRequest?

    private override init() {
        self.state = .notInstalled
        super.init()
    }

    /// Submit an activation request. The first time this runs the user
    /// must approve the extension in System Settings → Login Items & Extensions.
    public func activate() {
        guard state != .requestPending && state != .awaitingUserApproval else { return }
        state = .requestPending
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionBundleId,
            queue: .main
        )
        request.delegate = self
        pendingAction = .activation
        pendingRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted activation request for \(self.extensionBundleId, privacy: .public)")
    }

    /// Request a deactivation (used in development / uninstall flow).
    public func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: extensionBundleId,
            queue: .main
        )
        request.delegate = self
        pendingAction = .deactivation
        pendingRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    public func assumeActivatedFromInstalledManager() {
        state = .activated
        lastMessage = nil
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {

    nonisolated public func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always replace older builds during development.
        return .replace
    }

    nonisolated public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.state = .awaitingUserApproval
            self.lastMessage = "Open System Settings → General → Login Items & Extensions → Network Extensions and click Allow."
            self.log.info("system extension awaiting user approval")
        }
    }

    nonisolated public func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed:
                if self.pendingAction == .deactivation {
                    self.state = .notInstalled
                    self.log.info("system extension deactivation completed")
                } else {
                    self.state = .activated
                    self.log.info("system extension activation completed")
                }
                self.lastMessage = nil
            case .willCompleteAfterReboot:
                self.state = .awaitingUserApproval
                self.lastMessage = "A reboot is required to finish the install."
            @unknown default:
                self.state = .failed("Unknown activation result")
            }
            self.pendingAction = nil
            self.pendingRequest = nil
        }
    }

    nonisolated public func request(
        _ request: OSSystemExtensionRequest,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            self.lastMessage = error.localizedDescription
            self.log.error("system extension activation failed: \(error.localizedDescription, privacy: .public)")
            self.pendingAction = nil
            self.pendingRequest = nil
        }
    }
}
