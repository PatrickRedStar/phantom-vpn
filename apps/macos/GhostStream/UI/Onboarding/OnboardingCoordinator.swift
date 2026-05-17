//
//  OnboardingCoordinator.swift
//  GhostStream (macOS)
//
//  Finite-state machine driving the multi-step onboarding wizard.
//  Each step represents a single permission or configuration boundary
//  the user must cross before they can connect.
//
//  Flow:
//    paste            → user pastes a ghs:// connection string
//    installExt       → user authorises the system extension install
//    awaitingApproval → live polling while user approves in System Settings
//    configureVpn     → app saves NETunnelProviderManager (Allow VPN dialog)
//    ready            → terminal — wizard fades and Welcome window closes
//
//  The coordinator owns the cross-cutting state (current step, last error,
//  polling task) and exposes intents (`advanceFromPaste`, `kickOffInstall`,
//  `configureVpn`, `finish`) the SwiftUI views call without knowing the
//  underlying NetworkExtension / SystemExtensions plumbing.
//

import AppKit
import Foundation
import NetworkExtension
import Observation
import PhantomKit
import SystemExtensions
import os.log

@MainActor
@Observable
public final class OnboardingCoordinator {

    public enum Step: Int, Comparable, CaseIterable {
        case paste = 0
        case installExt = 1
        case awaitingApproval = 2
        case configureVpn = 3
        case ready = 4

        public static func < (lhs: Step, rhs: Step) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public private(set) var step: Step = .paste
    public private(set) var lastError: String?
    public private(set) var awaitingVpnApproval: Bool = false

    public weak var profiles: ProfilesStore?
    public weak var sysExt: SystemExtensionInstaller?
    public weak var tunnel: VpnTunnelController?
    public weak var preferences: PreferencesStore?

    private let log = Logger(subsystem: "com.ghoststream.client", category: "OnboardingCoordinator")
    private var pollTask: Task<Void, Never>?
    private var statusObserver: NSObjectProtocol?
    /// UI-R4-R03: race between `configureVpn` and `dismissedBeforeReady`.
    /// The install call (`tunnel.installOnly`) can take seconds to round
    /// trip through the SystemExtensions XPC; if the user closes the
    /// Welcome window during that window the coordinator was reset to
    /// `.paste` but the in-flight Task could still arrive and transition
    /// back to `.ready`, leaving the FSM at the wrong step. We now
    /// keep a handle on the live install Task so `dismissedBeforeReady`
    /// can cancel it before resetting.
    private var installTask: Task<Void, Never>?

    public init() {}

    /// Re-evaluate which step the user is on based on the current state of
    /// the world (profile imported? sys-ext activated? NEManager configured?).
    /// Called when the Welcome window opens.
    public func resync() async {
        if let profiles, profiles.activeProfile == nil {
            transition(to: .paste)
            return
        }

        if let tunnel {
            if tunnel.manager == nil {
                try? await tunnel.loadFromPreferences()
            }
            if isGhostStreamManagerConfigured(tunnel.manager) {
                sysExt?.assumeActivatedFromInstalledManager()
                transition(to: .ready)
                return
            }
        }

        switch sysExt?.state {
        case .activated:
            // Sys-ext done — see if NEManager is configured.
            if let tunnel, tunnel.manager == nil {
                try? await tunnel.loadFromPreferences()
            }
            if let mgr = tunnel?.manager,
               let proto = mgr.protocolConfiguration as? NETunnelProviderProtocol,
               proto.providerBundleIdentifier == "com.ghoststream.client.tunnel",
               mgr.isEnabled {
                transition(to: .ready)
            } else {
                transition(to: .configureVpn)
            }
        case .awaitingUserApproval, .requestPending:
            transition(to: .awaitingApproval)
            startPollingApproval()
        case .failed:
            transition(to: .installExt)
        case .notInstalled, .none:
            transition(to: .installExt)
        }
    }

    // MARK: - Step intents

    /// Step 1 → Step 2: profile imported, ask user to authorise sys-ext.
    public func didImportProfile() {
        log.info("paste step complete — moving to install extension")
        lastError = nil
        transition(to: .installExt)
    }

    /// Step 2 → Step 3: user clicks "Установить" — kick off
    /// `OSSystemExtensionRequest.activationRequest`. Apple may immediately
    /// surface the Allow prompt or may require the user to navigate to
    /// System Settings. Either way we move to `awaitingApproval` and poll.
    public func kickOffInstall() {
        guard let sysExt else { return }
        log.info("user approved install — submitting activation request")
        lastError = nil
        sysExt.activate()
        transition(to: .awaitingApproval)
        startPollingApproval()
    }

    /// Step 3 → Step 4: extension is `.activated`, install the
    /// NETunnelProviderManager. macOS will show the "VPN configurations"
    /// allow dialog; we observe `NEVPNStatusDidChange` to detect success.
    ///
    /// UI-R4-R03: the underlying `installOnly` call can sit in XPC for
    /// several seconds. If the user closes the Welcome window during
    /// that window, `dismissedBeforeReady` resets the FSM — but the
    /// in-flight Task used to keep running and call `transition(to:
    /// .ready)` afterwards. We now run the install through a stashed
    /// `Task` handle so the dismiss path can cancel it, and we re-check
    /// `Task.isCancelled` before mutating state in the completion arm.
    public func configureVpn() async {
        guard let profiles, let tunnel,
              let profile = profiles.activeProfile else {
            lastError = "Профиль исчез — вернитесь к шагу 1"
            transition(to: .paste)
            return
        }
        log.info("configuring NETunnelProviderManager for profile \(profile.id, privacy: .public)")
        awaitingVpnApproval = true

        installTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Install but DON'T start the tunnel yet — we just want the
                // user to grant the system VPN config permission. Starting
                // happens from the menu / dashboard once wizard finishes.
                try await tunnel.installOnly(profile: profile)
                if Task.isCancelled {
                    self.log.info("configureVpn task cancelled before completion")
                    return
                }
                self.awaitingVpnApproval = false
                self.lastError = nil
                self.sysExt?.assumeActivatedFromInstalledManager()
                self.log.info("NEManager saved — wizard complete")
                self.transition(to: .ready)
            } catch {
                if Task.isCancelled {
                    self.log.info("configureVpn task cancelled before completion (error swallowed)")
                    return
                }
                self.awaitingVpnApproval = false
                self.lastError = error.localizedDescription
                self.log.error("VPN configure failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        installTask = task
        await task.value
    }

    /// Wizard finished — caller closes the Welcome window.
    public func finish() {
        stopPolling()
    }

    /// UI-R2-N23: the user closed the Welcome window before the
    /// wizard reached `.ready` (typically by ⌘W). Stop any polling
    /// tasks and reset the FSM to `.paste` so the next time the user
    /// opens setup we don't show "Жду разрешения" stuck on an
    /// approval the user can't actually grant from the missing
    /// window. Idempotent on `.ready`.
    ///
    /// UI-R4-R03: also cancel any in-flight `installOnly` Task so it
    /// can't race past the reset and re-transition to `.ready`.
    public func dismissedBeforeReady() {
        stopPolling()
        installTask?.cancel()
        installTask = nil
        awaitingVpnApproval = false
        lastError = nil
        if step != .ready {
            step = .paste
        }
    }

    // MARK: - Deeplinks

    public static func openSystemSettingsLoginItems() {
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points")!
        NSWorkspace.shared.open(url)
    }

    public static func openSystemSettingsVpn() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?VPN")!
        NSWorkspace.shared.open(url)
    }

    public static func openSystemSettingsPrivacy() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internal

    private func transition(to next: Step) {
        guard step != next else { return }
        log.info("step \(self.step.rawValue, privacy: .public) → \(next.rawValue, privacy: .public)")
        step = next
        if next != .awaitingApproval {
            stopPolling()
        }
    }

    private func startPollingApproval() {
        stopPolling()
        pollTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                guard let sx = self.sysExt else { break }
                switch sx.state {
                case .activated:
                    self.log.info("polling detected .activated — advancing")
                    self.transition(to: .configureVpn)
                    return
                case .failed(let msg):
                    self.lastError = msg
                    self.transition(to: .installExt)
                    return
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func isGhostStreamManagerConfigured(_ manager: NETunnelProviderManager?) -> Bool {
        guard let manager,
              let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        else { return false }

        return proto.providerBundleIdentifier == "com.ghoststream.client.tunnel" && manager.isEnabled
    }
}
