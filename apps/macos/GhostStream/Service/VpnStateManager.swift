//
//  VpnStateManager.swift
//  GhostStream (macOS)
//
//  Single source of truth for VPN state. The only public observable is
//  `statusFrame` — the same StatusFrame that the system extension publishes
//  through `snapshot.json`. There is no separate `state` field, so views
//  cannot accidentally desync from the runtime.
//
//  Refresh cascade (event-driven, no per-second polling):
//    1. NEVPNStatusDidChange  — primary trigger after any tunnel state shift
//    2. Darwin notifications  — extension calls these when it writes snapshot
//    3. 10s safety-net poll   — covers the rare case where (1)/(2) misfire
//
//  The active NETunnelProviderManager is cached on the actor so other stores
//  (TunnelLogStore, UpstreamVpnMonitor) don't each call
//  `loadAllFromPreferences` on every tick — that XPC call was the source of
//  the "Loading all configurations" log spam visible in Console.
//

import Foundation
import Darwin
import NetworkExtension
import Observation
import PhantomKit

@MainActor
@Observable
public final class VpnStateManager {

    public static let shared = VpnStateManager()

    public private(set) var statusFrame: StatusFrame = .disconnected

    private let defaults: UserDefaults
    private let snapshotPayloadKey = "vpn.statusFrame.v1"
    private let snapshotUpdatedAtKey = "vpn.statusFrame.updatedAt"
    private let providerBundleId = "com.ghoststream.vpn.tunnel"
    private let snapshotFreshnessInterval: TimeInterval = 3
    private let safetyNetInterval: UInt64 = 10_000_000_000

    private var lastInterfaceSample: InterfaceSample?

    private var cachedManager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var safetyNetTask: Task<Void, Never>?

    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.ghoststream.vpn"
        )
    }

    private var snapshotURL: URL? {
        containerURL?.appendingPathComponent("snapshot.json")
    }

    private init() {
        self.defaults = UserDefaults(suiteName: "group.com.ghoststream.vpn")!
        self.loadSnapshot()
        self.observeDarwinNotifications()
        Task { @MainActor [weak self] in
            await self?.bootstrap()
        }
        self.startSafetyNetPolling()
    }

    /// Returns the cached manager handle, loading it on demand. Used by other
    /// stores (logs, upstream monitor) so they don't each fire XPC into
    /// `nesessionmanager` on every tick.
    public func cachedOrLoadManager() async -> NETunnelProviderManager? {
        if let cachedManager { return cachedManager }
        return await refreshCachedManager()
    }

    private func bootstrap() async {
        await refreshCachedManager()
        await refreshLiveTunnelStatus()
    }

    private func observeDarwinNotifications() {
        DarwinNotifications.observe(DarwinNotifications.stateChanged) { [weak self] in
            Task { @MainActor in
                self?.loadSnapshot()
                await self?.refreshLiveTunnelStatus()
            }
        }
    }

    @discardableResult
    private func refreshCachedManager() async -> NETunnelProviderManager? {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let manager = selectGhostStreamManager(from: managers)
            cachedManager = manager
            if statusObserver == nil, let manager {
                installStatusObserver(for: manager)
            }
            return manager
        } catch {
            return cachedManager
        }
    }

    private func installStatusObserver(for manager: NETunnelProviderManager) {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshLiveTunnelStatus()
            }
        }
    }

    private func startSafetyNetPolling() {
        safetyNetTask?.cancel()
        safetyNetTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.safetyNetTick()
            }
        }
    }

    private func safetyNetTick() async {
        if cachedManager == nil {
            await refreshCachedManager()
        }
        await refreshLiveTunnelStatus()
    }

    @discardableResult
    private func loadSnapshot() -> Bool {
        let fileData = snapshotURL.flatMap { try? Data(contentsOf: $0) }
        let storedData = defaults.data(forKey: snapshotPayloadKey)

        guard let data = fileData ?? storedData,
              let frame = try? JSONDecoder().decode(StatusFrame.self, from: data)
        else { return false }

        statusFrame = frame
        return true
    }

    @discardableResult
    private func refreshLiveTunnelStatus() async -> Bool {
        guard let manager = await cachedOrLoadManager() else {
            if !hasRecentRuntimeSnapshot() {
                statusFrame = .disconnected
            }
            return false
        }

        guard isActiveNetworkExtensionStatus(manager.connection.status),
              let session = manager.connection as? NETunnelProviderSession
        else {
            applyNetworkExtensionFallback(manager: manager)
            return false
        }

        do {
            let response = try await TunnelIpcBridge(session: session).send(.getStatus)
            guard case .status(let frame) = response else {
                loadSnapshot()
                return false
            }
            statusFrame = frame
            return true
        } catch {
            if !hasRecentRuntimeSnapshot() {
                applyNetworkExtensionFallback(manager: manager)
            } else {
                loadSnapshot()
            }
            return false
        }
    }

    private func applyNetworkExtensionFallback(manager: NETunnelProviderManager) {
        guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
            return
        }
        applyNetworkExtensionStatus(manager.connection.status, manager: manager, protocol: proto)
    }

    private func hasRecentRuntimeSnapshot(now: Date = Date()) -> Bool {
        if let url = snapshotURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date,
           now.timeIntervalSince(modified) <= snapshotFreshnessInterval
        {
            return true
        }

        let updatedAt = defaults.double(forKey: snapshotUpdatedAtKey)
        guard updatedAt > 0 else { return false }
        return now.timeIntervalSince1970 - updatedAt <= snapshotFreshnessInterval
    }

    private func selectGhostStreamManager(
        from managers: [NETunnelProviderManager]
    ) -> NETunnelProviderManager? {
        let ghostManagers = managers.filter { candidate in
            (candidate.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == providerBundleId
        }

        return ghostManagers.first { isActiveNetworkExtensionStatus($0.connection.status) }
            ?? ghostManagers.first(where: \.isEnabled)
            ?? ghostManagers.first
    }

    private func isActiveNetworkExtensionStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting:
            return true
        case .disconnected, .invalid:
            return false
        @unknown default:
            return false
        }
    }

    private func applyNetworkExtensionStatus(
        _ status: NEVPNStatus,
        manager: NETunnelProviderManager,
        protocol proto: NETunnelProviderProtocol
    ) {
        let frameState: ConnState
        let connectedDate: Date?
        switch status {
        case .connected:
            frameState = .connected
            connectedDate = manager.connection.connectedDate ?? Date()
        case .connecting:
            frameState = .connecting
            connectedDate = nil
        case .reasserting:
            frameState = .reconnecting
            connectedDate = nil
        case .disconnecting, .disconnected, .invalid:
            frameState = .disconnected
            connectedDate = nil
        @unknown default:
            frameState = .disconnected
            connectedDate = nil
        }

        statusFrame = makeNetworkExtensionStatusFrame(
            state: frameState,
            connectedDate: connectedDate,
            profile: profile(from: proto),
            protocol: proto
        )
    }

    private func makeNetworkExtensionStatusFrame(
        state: ConnState,
        connectedDate: Date?,
        profile: VpnProfile?,
        protocol proto: NETunnelProviderProtocol
    ) -> StatusFrame {
        let sessionSecs: UInt64
        if let connectedDate {
            sessionSecs = UInt64(max(0, Date().timeIntervalSince(connectedDate)))
        } else {
            sessionSecs = 0
        }
        let counters = state == .connected ? interfaceCounters(for: profile) : .zero

        return StatusFrame(
            state: state,
            sessionSecs: sessionSecs,
            bytesRx: counters.rxBytes,
            bytesTx: counters.txBytes,
            rateRxBps: counters.rateRxBps,
            rateTxBps: counters.rateTxBps,
            nStreams: state == .connected ? 1 : 0,
            streamsUp: state == .connected ? 1 : 0,
            streamActivity: Array(repeating: 0, count: 16),
            rttMs: nil,
            tunAddr: nonEmpty(profile?.tunAddr),
            serverAddr: nonEmpty(profile?.serverAddr) ?? nonEmpty(proto.serverAddress),
            sni: nonEmpty(profile?.serverName),
            lastError: nil,
            reconnectAttempt: nil,
            reconnectNextDelaySecs: nil
        )
    }

    private func profile(from proto: NETunnelProviderProtocol) -> VpnProfile? {
        guard let profileData = proto.providerConfiguration?["profile"] as? Data else {
            return nil
        }

        return try? JSONDecoder().decode(VpnProfile.self, from: profileData)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func interfaceCounters(for profile: VpnProfile?) -> InterfaceRates {
        guard let sample = activeUtunSample(preferredTunAddr: profile?.tunAddr) else {
            lastInterfaceSample = nil
            return .zero
        }

        defer { lastInterfaceSample = sample }
        guard let previous = lastInterfaceSample,
              previous.name == sample.name
        else {
            return InterfaceRates(rxBytes: sample.rxBytes, txBytes: sample.txBytes, rateRxBps: 0, rateTxBps: 0)
        }

        let dt = max(0.001, sample.sampledAt.timeIntervalSince(previous.sampledAt))
        let rxDelta = sample.rxBytes >= previous.rxBytes ? sample.rxBytes - previous.rxBytes : 0
        let txDelta = sample.txBytes >= previous.txBytes ? sample.txBytes - previous.txBytes : 0
        return InterfaceRates(
            rxBytes: sample.rxBytes,
            txBytes: sample.txBytes,
            rateRxBps: Double(rxDelta) / dt,
            rateTxBps: Double(txDelta) / dt
        )
    }

    private func activeUtunSample(preferredTunAddr: String?) -> InterfaceSample? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }

        let preferredAddress = preferredTunAddr?.split(separator: "/").first.map(String.init)
        var addressesByName: [String: String] = [:]
        var countersByName: [String: (rx: UInt64, tx: UInt64)] = [:]

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let namePtr = current.pointee.ifa_name,
                  let addr = current.pointee.ifa_addr
            else { continue }

            let name = String(cString: namePtr)
            guard name.hasPrefix("utun") else { continue }

            let family = Int32(addr.pointee.sa_family)
            if family == AF_INET {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result == 0 {
                    addressesByName[name] = String(cString: host)
                }
            } else if family == AF_LINK, let data = current.pointee.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self).pointee
                countersByName[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
            }
        }

        let candidates = countersByName.map { name, counters in
            InterfaceSample(
                name: name,
                address: addressesByName[name],
                rxBytes: counters.rx,
                txBytes: counters.tx,
                sampledAt: Date()
            )
        }

        if let preferredAddress,
           let preferred = candidates.first(where: { $0.address == preferredAddress })
        {
            return preferred
        }

        return candidates.max { lhs, rhs in
            (lhs.rxBytes + lhs.txBytes) < (rhs.rxBytes + rhs.txBytes)
        }
    }
}

private struct InterfaceSample {
    let name: String
    let address: String?
    let rxBytes: UInt64
    let txBytes: UInt64
    let sampledAt: Date
}

private struct InterfaceRates {
    static let zero = InterfaceRates(rxBytes: 0, txBytes: 0, rateRxBps: 0, rateTxBps: 0)

    let rxBytes: UInt64
    let txBytes: UInt64
    let rateRxBps: Double
    let rateTxBps: Double
}
