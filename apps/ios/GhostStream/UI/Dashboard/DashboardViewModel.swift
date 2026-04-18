//
//  DashboardViewModel.swift
//  GhostStream
//
//  Main-actor observable VM for the Dashboard screen. Uses push-based
//  StatusFrame from VpnStateManager instead of polling PhantomBridge.stats().

import Foundation
import Observation
import PhantomKit
import os.log

/// A single stats sample tied to the wall-clock time it was captured.
struct StatSample: Equatable {
    let at: Date
    let rxRate: Double
    let txRate: Double
    let bytesRx: Int64
    let bytesTx: Int64
}

@MainActor
@Observable
final class DashboardViewModel {

    // MARK: - Observable state

    private(set) var state: VpnState = .disconnected
    private(set) var samples: [StatSample] = []
    var window: ScopeWindow = .m1
    private(set) var timerText: String = "--:--:--"
    private(set) var subscriptionText: String?
    var preflightWarning: String?

    // MARK: - Dependencies

    private let tunnel = VpnTunnelController()
    private let log = Logger(subsystem: "com.ghoststream.vpn", category: "DashboardVM")
    private let maxSamples = 3600

    nonisolated(unsafe) private var sampleTask: Task<Void, Never>?
    nonisolated(unsafe) private var timerTask: Task<Void, Never>?
    nonisolated(unsafe) private var subscriptionTask: Task<Void, Never>?
    private var stopped = false

    // MARK: - Derived samples for the chart

    var rxSamples: [Double] { windowedSamples().map(\.rxRate) }
    var txSamples: [Double] { windowedSamples().map(\.txRate) }

    private func windowedSamples() -> [StatSample] {
        let limit = window.rawValue
        if samples.count <= limit { return samples }
        return Array(samples.suffix(limit))
    }

    // MARK: - Lifecycle

    init() {
        self.state = VpnStateManager.shared.state
        observeState()
        restart(for: state)
    }

    deinit {
        sampleTask?.cancel()
        timerTask?.cancel()
        subscriptionTask?.cancel()
    }

    func onAppear() {
        state = VpnStateManager.shared.state
        restart(for: state)
    }

    // MARK: - Actions

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

    func stop() {
        VpnStateManager.shared.update(.disconnecting)
        tunnel.stop()
    }

    func cycleWindow() { window = window.next }
    func dismissPreflight() { preflightWarning = nil }

    // MARK: - Internals

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
        case (.connected, .connected): return true
        case (.error, .error): return true
        default: return false
        }
    }

    private func restart(for state: VpnState) {
        sampleTask?.cancel(); sampleTask = nil
        timerTask?.cancel(); timerTask = nil
        subscriptionTask?.cancel(); subscriptionTask = nil

        switch state {
        case .connected(let since, _):
            startSampleLoop()
            startTimerLoop(since: since)
            startSubscriptionLoop()
        case .connecting:
            timerText = "--:--:--"
            startSampleLoop()
        case .disconnected, .error, .disconnecting:
            timerText = "--:--:--"
            samples.removeAll()
        }
    }

    /// Samples StatusFrame every 1s to build the scope chart.
    private func startSampleLoop() {
        sampleTask = Task { @MainActor [weak self] in
            while let self, !self.stopped, !Task.isCancelled {
                let sf = VpnStateManager.shared.statusFrame
                let sample = StatSample(
                    at: Date(),
                    rxRate: sf.rateRxBps,
                    txRate: sf.rateTxBps,
                    bytesRx: Int64(sf.bytesRx),
                    bytesTx: Int64(sf.bytesTx)
                )
                self.samples.append(sample)
                if self.samples.count > self.maxSamples {
                    self.samples.removeFirst(self.samples.count - self.maxSamples)
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

    private func startSubscriptionLoop() {
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

    static func format(duration: TimeInterval) -> String {
        let s = max(0, Int(duration))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return String(format: "%02d:%02d:%02d", h, m, sec)
    }
}
