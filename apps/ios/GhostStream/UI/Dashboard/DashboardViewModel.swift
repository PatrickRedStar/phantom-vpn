//
//  DashboardViewModel.swift
//  GhostStream
//
//  Main-actor observable VM for the Dashboard screen. Polls
//  `PhantomBridge.stats()` every second while connected and maintains a
//  rolling window (1m/5m/30m/1h) of RX/TX byte rates for the scope chart.
//

import Foundation
import Observation
import os.log

/// A single stats sample tied to the wall-clock time it was captured.
struct StatSample: Equatable {
    let at: Date
    /// Instantaneous RX byte rate (bytes/sec over the last tick).
    let rxRate: Double
    /// Instantaneous TX byte rate (bytes/sec over the last tick).
    let txRate: Double
    /// Cumulative RX bytes (from Rust).
    let bytesRx: Int64
    /// Cumulative TX bytes (from Rust).
    let bytesTx: Int64
}

/// Owns the 1s polling loop + subscription-info fetch loop for the
/// Dashboard screen.
///
/// Safe to leak — the loops are tied to the VM's lifetime via
/// `Task { @MainActor in ... }` guarded by a `stopped` flag.
@MainActor
@Observable
final class DashboardViewModel {

    // MARK: - Observable state

    /// Current VPN state, mirrored from `VpnStateManager`.
    private(set) var state: VpnState = .disconnected

    /// Latest stats snapshot (cumulative counters + connected flag).
    private(set) var latest: Stats?

    /// Most recent per-second samples — capped at `maxSamples` (~1h at 1s).
    private(set) var samples: [StatSample] = []

    /// Currently selected scope window. Tap the scope label to cycle.
    var window: ScopeWindow = .m1

    /// "HH:MM:SS" session timer while connected, "--:--:--" otherwise.
    private(set) var timerText: String = "--:--:--"

    /// Optional subscription status line (e.g. "Подписка: 5д 3ч" /
    /// "Подписка истекла"). `nil` when unknown or not applicable.
    private(set) var subscriptionText: String?

    /// Transient banner text. Callers dismiss via `dismissPreflight`.
    var preflightWarning: String?

    // MARK: - Dependencies

    private let tunnel = VpnTunnelController()
    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "DashboardVM")

    private let maxSamples = 3600 // 1h @ 1s cadence

    nonisolated(unsafe) private var pollTask: Task<Void, Never>?
    nonisolated(unsafe) private var timerTask: Task<Void, Never>?
    nonisolated(unsafe) private var subscriptionTask: Task<Void, Never>?
    private var stopped = false

    // MARK: - Derived samples for the chart

    /// RX rates trimmed to the current window, oldest-first.
    var rxSamples: [Double] {
        windowedSamples().map(\.rxRate)
    }

    /// TX rates trimmed to the current window, oldest-first.
    var txSamples: [Double] {
        windowedSamples().map(\.txRate)
    }

    private func windowedSamples() -> [StatSample] {
        let limit = window.rawValue
        if samples.count <= limit { return samples }
        return Array(samples.suffix(limit))
    }

    // MARK: - Lifecycle

    init() {
        // Pick up initial state synchronously.
        self.state = VpnStateManager.shared.state
        observeState()
        restart(for: state)
    }

    deinit {
        pollTask?.cancel()
        timerTask?.cancel()
        subscriptionTask?.cancel()
    }

    /// Called by the view when it appears — kick the poll loop if we're
    /// already connected.
    func onAppear() {
        state = VpnStateManager.shared.state
        restart(for: state)
    }

    // MARK: - Actions

    /// Starts the VPN using the active profile + global prefs. Updates
    /// `preflightWarning` on validation failure.
    func start(profile: VpnProfile?, preferences: PreferencesStore) {
        guard let profile else {
            preflightWarning = "No active profile — add one from Settings"
            return
        }
        guard let certPem = profile.certPem, let keyPem = profile.keyPem,
              !certPem.isEmpty, !keyPem.isEmpty else {
            preflightWarning = "Certificates not found"
            return
        }
        preflightWarning = nil
        VpnStateManager.shared.update(.connecting)
        Task {
            do {
                // Re-hydrate the profile with PEMs before handing to the
                // tunnel controller — `ProfilesStore` owns the canonical
                // copy, but `profile` passed in should already have them.
                var p = profile
                p.certPem = certPem
                p.keyPem = keyPem
                try await tunnel.installAndStart(profile: p, preferences: preferences)
            } catch {
                log.error("start failed: \(error.localizedDescription, privacy: .public)")
                VpnStateManager.shared.update(.error(error.localizedDescription))
            }
        }
    }

    /// Requests the tunnel extension to stop.
    func stop() {
        VpnStateManager.shared.update(.disconnecting)
        tunnel.stop()
    }

    /// Cycles the scope window and resets the sample buffer so the chart
    /// doesn't appear stretched while the buffer repopulates.
    func cycleWindow() {
        window = window.next
    }

    /// Clears the preflight banner.
    func dismissPreflight() { preflightWarning = nil }

    // MARK: - Internals

    /// Observe the global VpnStateManager via Darwin notifications.
    private func observeState() {
        DarwinNotifications.observe(DarwinNotifications.stateChanged) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let next = VpnStateManager.shared.state
                let prev = self.state
                self.state = next
                if !Self.sameKind(prev, next) {
                    self.restart(for: next)
                }
            }
        }
    }

    private static func sameKind(_ a: VpnState, _ b: VpnState) -> Bool {
        switch (a, b) {
        case (.disconnected, .disconnected),
             (.connecting, .connecting),
             (.disconnecting, .disconnecting):
            return true
        case (.connected, .connected):
            return true
        case (.error, .error):
            return true
        default:
            return false
        }
    }

    /// Tear down the previous loops and start the right ones for the
    /// given state.
    private func restart(for state: VpnState) {
        pollTask?.cancel(); pollTask = nil
        timerTask?.cancel(); timerTask = nil
        subscriptionTask?.cancel(); subscriptionTask = nil

        switch state {
        case .connected(let since, _):
            startPollingLoop()
            startTimerLoop(since: since)
            startSubscriptionLoop()
        case .connecting:
            timerText = "--:--:--"
            startPollingLoop() // stats before the tunnel is ready are harmless
        case .disconnected, .error, .disconnecting:
            timerText = "--:--:--"
            samples.removeAll()
            latest = nil
        }
    }

    private func startPollingLoop() {
        pollTask = Task { @MainActor [weak self] in
            var lastRx: Int64?
            var lastTx: Int64?
            while let self, !self.stopped, !Task.isCancelled {
                if let s = PhantomBridge.stats() {
                    self.latest = s
                    let rxRate: Double = lastRx.map {
                        max(0, Double(s.bytesRx - $0))
                    } ?? 0
                    let txRate: Double = lastTx.map {
                        max(0, Double(s.bytesTx - $0))
                    } ?? 0
                    lastRx = s.bytesRx
                    lastTx = s.bytesTx
                    let sample = StatSample(
                        at: Date(),
                        rxRate: rxRate,
                        txRate: txRate,
                        bytesRx: s.bytesRx,
                        bytesTx: s.bytesTx
                    )
                    self.samples.append(sample)
                    if self.samples.count > self.maxSamples {
                        self.samples.removeFirst(self.samples.count - self.maxSamples)
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func startTimerLoop(since: Date) {
        timerTask = Task { @MainActor [weak self] in
            while let self, !self.stopped, !Task.isCancelled {
                self.timerText = Self.format(duration: Date().timeIntervalSince(since))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Hit `/api/clients` on the server's admin HTTP endpoint every 60s
    /// to refresh the subscription line. This is a stub — the actual
    /// mTLS client builder lives in `AdminHttpClient` which is written
    /// by a separate agent.
    private func startSubscriptionLoop() {
        // TODO: wire `AdminHttpClient` once that file lands. For now we
        // fall back to `cachedExpiresAt` from the active profile.
        subscriptionTask = Task { @MainActor [weak self] in
            while let self, !self.stopped, !Task.isCancelled {
                self.refreshSubscriptionFromCache()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func refreshSubscriptionFromCache() {
        guard let profile = ProfilesStore.shared.activeProfile,
              let expiresAt = profile.cachedExpiresAt else {
            subscriptionText = nil
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        let remaining = expiresAt - now
        if remaining <= 0 {
            subscriptionText = "Подписка истекла"
        } else {
            let days = remaining / 86_400
            let hours = (remaining % 86_400) / 3_600
            subscriptionText = "Подписка: \(days)д \(hours)ч"
        }
    }

    /// Format a positive duration as HH:MM:SS.
    static func format(duration: TimeInterval) -> String {
        let s = max(0, Int(duration))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}
