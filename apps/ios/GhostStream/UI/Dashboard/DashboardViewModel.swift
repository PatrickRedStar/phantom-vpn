//
//  DashboardViewModel.swift
//  GhostStream
//
//  Main-actor observable VM for the Dashboard screen. Uses push-based
//  StatusFrame from VpnStateManager instead of polling PhantomBridge.stats().

import PhantomUI
import Foundation
import NetworkExtension
import Observation
import PhantomKit
import UserNotifications
import os.log

/// A single stats sample tied to the wall-clock time it was captured.
struct StatSample: Equatable {
    let at: Date
    let rxRate: Double
    let txRate: Double
    let bytesRx: Int64
    let bytesTx: Int64
}

/// SwiftUI builds a new instance every time `DashboardView`'s struct is
/// rebuilt and keeps only the first, so `init` must stay free of side
/// effects: no observers, no loops, no reads of observable state (a read
/// there made the parent body depend on it). Work runs from the view's
/// `.task`s and stops when the screen goes away.
@MainActor
@Observable
final class DashboardViewModel {

    // MARK: - Observable state

    private(set) var samples: [StatSample] = []
    var window: ScopeWindow = .m1
    private(set) var timerText: String = "--:--:--"
    var preflightWarning: String?

    /// App-wide state; views reading it re-render on its changes.
    var state: VpnState { VpnStateManager.shared.state }

    // MARK: - Dependencies

    private let tunnel = VpnTunnelController()
    private let log = Logger(subsystem: "com.ghoststream.client", category: "DashboardVM")
    private let maxSamples = 3600
    @ObservationIgnored private var startTask: Task<Void, Never>?

    // MARK: - Derived samples for the chart

    var rxSamples: [Double] { windowedSamples().map(\.rxRate) }
    var txSamples: [Double] { windowedSamples().map(\.txRate) }

    private func windowedSamples() -> [StatSample] {
        let limit = window.rawValue
        if samples.count <= limit { return samples }
        return Array(samples.suffix(limit))
    }

    // MARK: - Lifecycle

    /// While the screen is visible: session timer and scope samples, 1 Hz.
    func run() async {
        tick()
        await VpnStateManager.shared.reconcileWithSystem()
        while !Task.isCancelled {
            tick()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// While connected and visible: /api/me now and every 5 minutes.
    func refreshEntitlements() async {
        // Asked once by iOS: the extension notifies on a fatal stop
        // (revoked / expired access, clock).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        while !Task.isCancelled {
            _ = await ProfileEntitlementRefresher.refreshActiveProfileIfConnected(profilesStore: .shared)
            try? await Task.sleep(nanoseconds: 300_000_000_000)
        }
    }

    // MARK: - Actions

    func start(profile: VpnProfile?, preferences: PreferencesStore) {
        guard let profile else {
            preflightWarning = AppStrings.localized("dashboard.preflight.no.profile")
            return
        }
        guard let certPem = profile.certPem, let keyPem = profile.keyPem,
              !certPem.isEmpty, !keyPem.isEmpty else {
            preflightWarning = AppStrings.localized("dashboard.preflight.no.certs")
            return
        }
        preflightWarning = nil
        VpnStateManager.shared.update(.connecting)
        startTask = Task {
            do {
                var p = profile
                p.certPem = certPem
                p.keyPem = keyPem
                try await tunnel.installAndStart(profile: p, preferences: preferences)
            } catch {
                // «Остановить попытку» cancelled the start; stop() owns the state.
                guard !Task.isCancelled else { return }
                log.error("start failed: \(error.localizedDescription, privacy: .public)")
                VpnStateManager.shared.update(.error(ConnectErrorHumanizer.humanize(
                    error.localizedDescription,
                    english: AppStrings.isEnglish
                )))
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        VpnStateManager.shared.update(.disconnecting)
        Task { @MainActor in
            await tunnel.stopAndWait()
            try? await Task.sleep(nanoseconds: 750_000_000)
            await VpnStateManager.shared.reconcileWithSystem()
        }
    }

    func cycleWindow() { window = window.next }
    func dismissPreflight() { preflightWarning = nil }

    // MARK: - Internals

    private func tick() {
        switch state {
        case .connected(let since, _), .reconnecting(let since, _):
            timerText = Self.format(duration: Date().timeIntervalSince(since))
            appendSample()
        case .connecting:
            timerText = "--:--:--"
            appendSample()
        case .disconnected, .error, .disconnecting:
            timerText = "--:--:--"
            if !samples.isEmpty { samples.removeAll() }
        }
    }

    private func appendSample() {
        let sf = VpnStateManager.shared.statusFrame
        samples.append(StatSample(
            at: Date(),
            rxRate: sf.rateRxBps,
            txRate: sf.rateTxBps,
            bytesRx: Int64(sf.bytesRx),
            bytesTx: Int64(sf.bytesTx)
        ))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    static func format(duration: TimeInterval) -> String {
        let s = max(0, Int(duration))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}
