//
//  VpnStateManager.swift
//  GhostStream (macOS)
//
//  Cross-process VPN state. Mirrors the iOS implementation —
//  observes `snapshot.json` in the App Group container plus Darwin
//  notifications, exposes an `@Observable` `statusFrame` for SwiftUI.
//

import Foundation
import Darwin
import NetworkExtension
import Observation
import PhantomKit

public enum VpnState: Equatable {
    case disconnected
    case connecting
    case connected(since: Date, serverName: String)
    case disconnecting
    case error(String)
}

extension VpnStatePayload {
    public static func from(_ state: VpnState) -> VpnStatePayload {
        switch state {
        case .disconnected:
            return .init(kind: .disconnected)
        case .connecting:
            return .init(kind: .connecting)
        case .connected(let since, let name):
            return .init(kind: .connected, since: since.timeIntervalSince1970, serverName: name)
        case .disconnecting:
            return .init(kind: .disconnecting)
        case .error(let msg):
            return .init(kind: .error, error: msg)
        }
    }

    public var asState: VpnState {
        switch kind {
        case .disconnected:  return .disconnected
        case .connecting:    return .connecting
        case .connected:
            let date = Date(timeIntervalSince1970: since ?? Date().timeIntervalSince1970)
            return .connected(since: date, serverName: serverName ?? "")
        case .disconnecting: return .disconnecting
        case .error:         return .error(error ?? "unknown")
        }
    }
}

@MainActor
@Observable
public final class VpnStateManager {

    public static let shared = VpnStateManager()

    public private(set) var state: VpnState = .disconnected
    public private(set) var statusFrame: StatusFrame = .disconnected

    private let defaults: UserDefaults
    private let payloadKey = "vpn.state.v1"
    private let snapshotPayloadKey = "vpn.statusFrame.v1"
    private let snapshotUpdatedAtKey = "vpn.statusFrame.updatedAt"
    private let providerBundleId = "com.ghoststream.vpn.tunnel"
    private let snapshotFreshnessInterval: TimeInterval = 3
    private var lastInterfaceSample: InterfaceSample?

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
        self.loadPayload()
        self.loadSnapshot()
        self.observeDarwinNotifications()
        self.startNetworkExtensionStatusPolling()
    }

    public func update(_ newState: VpnState) {
        state = newState
        writePayload(VpnStatePayload.from(newState))
        DarwinNotifications.post(DarwinNotifications.stateChanged)
    }

    private func observeDarwinNotifications() {
        DarwinNotifications.observe(DarwinNotifications.stateChanged) { [weak self] in
            Task { @MainActor in
                self?.loadPayload()
                self?.loadSnapshot()
                await self?.refreshNetworkExtensionStatusFallback()
            }
        }
    }

    private func startNetworkExtensionStatusPolling() {
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollNetworkExtensionStatus()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func pollNetworkExtensionStatus() async {
        if await refreshLiveTunnelStatus() {
            return
        }

        if hasRecentRuntimeSnapshot() {
            loadSnapshot()
            return
        }

        await refreshNetworkExtensionStatusFallback()
    }

    private func writePayload(_ payload: VpnStatePayload) {
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: payloadKey)
        }
    }

    private func loadPayload() {
        guard let data = defaults.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(VpnStatePayload.self, from: data)
        else { return }
        state = payload.asState
    }

    @discardableResult
    private func loadSnapshot() -> Bool {
        let fileData = snapshotURL.flatMap { try? Data(contentsOf: $0) }
        let storedData = defaults.data(forKey: snapshotPayloadKey)

        guard let data = fileData ?? storedData,
              let frame = try? JSONDecoder().decode(StatusFrame.self, from: data)
        else { return false }

        statusFrame = frame
        applyStatusFrame(frame)
        return true
    }

    private func applyStatusFrame(_ frame: StatusFrame) {
        switch frame.state {
        case .disconnected:
            state = .disconnected
        case .connecting:
            state = .connecting
        case .reconnecting:
            state = .connecting
        case .connected:
            let since = Date().addingTimeInterval(-Double(frame.sessionSecs))
            let serverName = frame.sni ?? frame.serverAddr ?? ""
            state = .connected(since: since, serverName: serverName)
        case .error:
            state = .error(frame.lastError ?? "unknown")
        }
    }

    private func refreshLiveTunnelStatus() async -> Bool {
        do {
            guard let manager = try await loadGhostStreamManager(),
                  isActiveNetworkExtensionStatus(manager.connection.status),
                  let session = manager.connection as? NETunnelProviderSession
            else { return false }

            let response = try await TunnelIpcBridge(session: session).send(.getStatus)
            guard case .status(let frame) = response else { return false }

            statusFrame = frame
            applyStatusFrame(frame)
            return true
        } catch {
            return false
        }
    }

    private func refreshNetworkExtensionStatusFallback() async {
        guard !hasRecentRuntimeSnapshot() else { return }

        do {
            guard let manager = try await loadGhostStreamManager(),
                  let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
            else { return }

            applyNetworkExtensionStatus(manager.connection.status, manager: manager, protocol: proto)
        } catch {
            return
        }
    }

    private func loadGhostStreamManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return selectGhostStreamManager(from: managers)
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
        switch status {
        case .connected:
            let connectedDate = manager.connection.connectedDate ?? Date()
            let profile = profile(from: proto)
            let serverName = nonEmpty(profile?.serverName)
                ?? nonEmpty(profile?.serverAddr)
                ?? nonEmpty(proto.serverAddress)
                ?? ""

            state = .connected(since: connectedDate, serverName: serverName)
            statusFrame = makeNetworkExtensionStatusFrame(
                state: .connected,
                connectedDate: connectedDate,
                profile: profile,
                protocol: proto
            )
        case .connecting:
            state = .connecting
            statusFrame = makeNetworkExtensionStatusFrame(
                state: .connecting,
                connectedDate: nil,
                profile: profile(from: proto),
                protocol: proto
            )
        case .reasserting:
            state = .connecting
            statusFrame = makeNetworkExtensionStatusFrame(
                state: .reconnecting,
                connectedDate: nil,
                profile: profile(from: proto),
                protocol: proto
            )
        case .disconnecting:
            state = .disconnecting
            statusFrame = makeNetworkExtensionStatusFrame(
                state: .disconnected,
                connectedDate: nil,
                profile: profile(from: proto),
                protocol: proto
            )
        case .disconnected, .invalid:
            state = .disconnected
            statusFrame = makeNetworkExtensionStatusFrame(
                state: .disconnected,
                connectedDate: nil,
                profile: profile(from: proto),
                protocol: proto
            )
        @unknown default:
            state = .disconnected
            statusFrame = makeNetworkExtensionStatusFrame(
                state: .disconnected,
                connectedDate: nil,
                profile: profile(from: proto),
                protocol: proto
            )
        }
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
