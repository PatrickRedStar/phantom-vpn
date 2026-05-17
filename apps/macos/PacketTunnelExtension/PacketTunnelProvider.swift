//
//  PacketTunnelProvider.swift
//  GhostStream macOS — system extension
//
//  Adapted from apps/ios/PacketTunnelProvider/PacketTunnelProvider.swift.
//  Same loadProfile / setTunnelNetworkSettings / outboundLoop pattern;
//  on macOS the host bundle is sibling to the system extension, so the
//  shared App Group container path is identical.
//

import Foundation
import Network
import NetworkExtension
import PhantomKit
import os.log

/// Bridge `PhantomKit.LogFrame` to the writer's protocol without leaking
/// PhantomKit into LogFileWriter itself. Ring-buffer ↔ file ↔ UI all read
/// the same struct.
extension LogFrame: LogFrameLike {}

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.ghoststream.client.tunnel", category: "tunnel")
    private let osLogPool = OSLogCategoryPool()
    /// Audit PROV-R2-R01 — `outboundTask`, `routeSettingsTask`,
    /// `handshakeTimeoutTask`, `pathMonitor`, `previousPathStatus`,
    /// `previousPathInterfaces`, `pathDebounceTask`, `reconnectingWatchdogTask`
    /// are mutated from multiple queues (`startTunnel`'s Task, `stopTunnel`'s
    /// Task, the IPC `handleAppMessage` queue, the `pathMonitorQueue`, the
    /// `wake`/`sleep` callbacks). The previous code had no synchronisation
    /// at all — readers could see torn writes and writers could clobber each
    /// other's task references, leaking Tasks. We funnel every access through
    /// `runtimeStateLock` via `withStateLock { ... }` so each mutation
    /// happens-before the next read.
    private var outboundTask: Task<Void, Never>?
    private var routeSettingsTask: Task<Void, Never>?
    /// ADR 0008 — verbose logging is sourced from the host App Group
    /// preferences at `startTunnel` time and pinned for the lifetime of
    /// the tunnel.
    private var verboseLog: Bool = false

    /// Audit PROV-C1 — fires `callStartCompletionOnce` with a timeout
    /// error if the runtime fails to reach `.connected` within
    /// `handshakeTimeoutSeconds`. Stays armed until the first
    /// `.connected` frame, then is cancelled.
    private var handshakeTimeoutTask: Task<Void, Never>?
    private static let handshakeTimeoutSeconds: UInt64 = 30

    /// Audit PROV-R2-N02 — watchdog that fires `forceRuntimeReconnect` if
    /// the runtime sits in `.reconnecting` for more than
    /// `reconnectingWatchdogSeconds` without reaching `.connected` or
    /// `.error`. Without this the UI can be stuck on "reconnecting" forever
    /// when the runtime's internal retry loop wedges.
    private var reconnectingWatchdogTask: Task<Void, Never>?
    private static let reconnectingWatchdogSeconds: UInt64 = 60

    /// Audit PROV-H1 / PROV-H2 / CONC-C2 — observe path changes so we can
    /// force a reconnect when interfaces flip (Wi-Fi → cellular, sleep
    /// teardown re-attach, etc.) instead of waiting for the runtime's
    /// 45 s idle timeout.
    ///
    /// `Network.NWPath` (Swift struct) is qualified so the compiler doesn't
    /// pick NetworkExtension's deprecated ObjC `NWPath` class — that one
    /// has no `.status` / `usesInterfaceType` API surface.
    private var pathMonitor: NWPathMonitor?
    private var previousPathStatus: Network.NWPath.Status?
    private var previousPathInterfaces: Set<NWInterface.InterfaceType>?
    /// Audit PROV-R2-N04 — NWPathMonitor can fire several updates within
    /// hundreds of milliseconds when the system enumerates interfaces (e.g.
    /// joining a Wi-Fi network: status flaps between satisfied/unsatisfied,
    /// interfaces flip across `[wifi]`, `[wifi, wiredEthernet]`, etc.).
    /// Without a debounce we'd kick a fresh `forceRuntimeReconnect` for each
    /// edge — draining the battery and racing the previous reconnect's
    /// `armHandshakeTimeout`. Coalesce updates onto a single 2 s window.
    private var pathDebounceTask: Task<Void, Never>?
    private static let pathDebounceSeconds: UInt64 = 2
    private let pathMonitorQueue = DispatchQueue(
        label: "com.ghoststream.client.tunnel.pathmonitor",
        qos: .utility
    )

    /// Audit IPC-C2 — `updateRoutePolicy` mutates network settings; back-to-back
    /// invocations would otherwise race `setTunnelNetworkSettings`. Serialise
    /// through this actor so each apply completes before the next starts.
    private let routePolicyApplier = RoutePolicyApplier()

    /// Last `StatusFrame` received from the runtime (or the synthetic state-only
    /// frame published while connecting). Single source of truth for IPC
    /// `getStatus` responses and snapshot fan-out.
    ///
    /// Per ADR 0007 the extension never recomputes telemetry — it only relays
    /// frames coming through `onStatus` and `onLog` callbacks plus a tiny
    /// state-only frame on connecting / error / disconnect.
    private var lastStatusFrame: StatusFrame = .disconnected
    private var recentLogFrames: [LogFrame] = []
    /// Audit PROV-R2-R01 — also guards `outboundTask`, `routeSettingsTask`,
    /// `handshakeTimeoutTask`, `pathMonitor`, `previousPathStatus`,
    /// `previousPathInterfaces`, `pathDebounceTask`, `reconnectingWatchdogTask`,
    /// `activeProfile`, and `activeSettings`. See those fields' docstrings
    /// for why mutation under this lock is required.
    private let runtimeStateLock = NSLock()
    private let snapshotPayloadKey = "vpn.statusFrame.v1"
    private let snapshotUpdatedAtKey = "vpn.statusFrame.updatedAt"
    private var activeProfile: VpnProfile?
    private var activeSettings: TunnelSettings?

    /// Single-call escape hatch around `runtimeStateLock`. Use this for every
    /// read/write of fields covered by the lock so we never have to remember
    /// the lock/unlock pair by hand — see audit PROV-R2-R01.
    @discardableResult
    private func withStateLock<T>(_ block: () -> T) -> T {
        runtimeStateLock.lock()
        defer { runtimeStateLock.unlock() }
        return block()
    }

    /// Apple forbids calling the `startTunnel` completionHandler more than
    /// once — the second call traps the extension. The handler can fire
    /// from multiple racing paths (the `onStatus` `.connected` callback,
    /// the fallback after `PhantomBridge.start` returns, and the outer
    /// `startTunnel` Task's `catch` block on a throw). All of them go
    /// through `callStartCompletionOnce(...)` so the check-and-set is
    /// atomic. The handler reference is cleared once fired so a fresh
    /// `startTunnel` cycle can install a new one.
    private let startCompletionLock = NSLock()
    private var startCompletionHandler: ((Error?) -> Void)?
    private var startCompletionFired = false

    // MARK: - Lifecycle

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // Stash the handler under the lock so every completion path (the
        // .connected onStatus callback, the post-`start` fallback, the
        // catch below) routes through a single atomic guard.
        startCompletionLock.lock()
        startCompletionHandler = completionHandler
        startCompletionFired = false
        startCompletionLock.unlock()

        Task {
            do {
                try await self.startTunnelAsync()
            } catch {
                self.log.error("startTunnel failed: \(error.localizedDescription, privacy: .public)")
                self.writeErrorSnapshot(error.localizedDescription)
                self.callStartCompletionOnce(error)
            }
        }
    }

    /// Atomic single-shot dispatcher for the `startTunnel` completion
    /// handler. Subsequent calls are dropped — see `startCompletionLock`
    /// docstring for why this guard exists.
    private func callStartCompletionOnce(_ error: Error?) {
        startCompletionLock.lock()
        if startCompletionFired {
            startCompletionLock.unlock()
            return
        }
        startCompletionFired = true
        let handler = startCompletionHandler
        startCompletionHandler = nil
        startCompletionLock.unlock()
        handler?(error)
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        log.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        // Audit PROV-R2-R01 — snapshot + clear task references under the
        // state lock so a concurrent IPC `.disconnect` or `wake()` can't
        // resurrect them after we've decided to tear down.
        let outbound = withStateLock { () -> Task<Void, Never>? in
            let captured = outboundTask
            outboundTask = nil
            routeSettingsTask?.cancel()
            routeSettingsTask = nil
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            reconnectingWatchdogTask?.cancel()
            reconnectingWatchdogTask = nil
            pathDebounceTask?.cancel()
            pathDebounceTask = nil
            activeProfile = nil
            activeSettings = nil
            return captured
        }
        stopPathMonitor()
        emitProviderEvent(
            level: "INF",
            category: "tunnel",
            event: "disconnect",
            fields: ["reason": String(reason.rawValue)]
        )

        // Audit CONC-R2-N03 / PROV-R2-N01 — wrap each teardown step in
        // `withTimeout` so the chain never exceeds the ~5 s SIGKILL deadline.
        // The Round 1 FFI change made `PhantomBridge.stop` block up to 9 s on
        // its own and `setTunnelNetworkSettings(nil)` can sit 1-3 s during a
        // bad sleep cycle; together they would always exceed the budget.
        Task {
            await withTimeout(seconds: 0.5) { @Sendable in
                outbound?.cancel()
                _ = await outbound?.value
            }
            // CONC-H1 — give the system a chance to tear down DNS/routes
            // before the runtime stops. `nil` clears the previously-applied
            // NEPacketTunnelNetworkSettings on the active interface.
            await withTimeout(seconds: 1.0) { [weak self] in
                guard let self else { return }
                try? await self.setTunnelNetworkSettings(nil)
            }
            await withTimeout(seconds: 1.0) { @Sendable in
                await PhantomBridge.shared.stop()
            }
            LogFileWriter.shared.flush()
            writeDisconnectedSnapshot()
            completionHandler()
        }
    }

    // MARK: - Power management (Audit PROV-H1 / CONC-C2)

    /// macOS NE framework calls `sleep(completionHandler:)` before the
    /// system suspends. Apple guidance: return ASAP. We don't try to
    /// preserve the runtime — sockets will be dead on wake anyway. The
    /// reconnection happens in `wake()`.
    override func sleep(completionHandler: @escaping () -> Void) {
        log.info("sleep — system suspending")
        emitProviderEvent(
            level: "INF",
            category: "tunnel",
            event: "sleep",
            fields: nil
        )
        super.sleep(completionHandler: completionHandler)
    }

    /// On wake the TCP sockets the runtime owns are typically dead.
    /// Restart the runtime end-to-end with the previously-loaded profile —
    /// simplest reliable path. We deliberately don't preserve the previous
    /// handshakeTimeoutTask: a fresh start re-arms its own.
    ///
    /// Audit PROV-R2-N05 — sleep tears down Wi-Fi/Ethernet drivers along
    /// with the runtime sockets, and the kernel takes 1-2 s after the wake
    /// signal to bring an interface back up. Kicking `forceRuntimeReconnect`
    /// immediately means TLS handshake races a half-attached interface and
    /// almost always times out via the 30 s handshake watchdog. Delay a
    /// brief 2 s window first so the path is steady by the time we open
    /// new sockets.
    override func wake() {
        super.wake()
        log.info("wake — delaying reconnect 2s for network readiness")
        emitProviderEvent(
            level: "INF",
            category: "tunnel",
            event: "wake",
            fields: nil
        )
        Task { [weak self] in
            let nanos = Self.pathDebounceSeconds * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.forceRuntimeReconnect(reason: "wake")
        }
    }

    /// Audit PROV-H1 — restart `PhantomBridge` while preserving the
    /// already-loaded profile/settings. Used by both `wake()` and the
    /// NWPathMonitor handler. Re-arms the handshake timeout via
    /// `armHandshakeTimeout()`.
    ///
    /// Audit PROV-R2-R02 — `armHandshakeTimeout` MUST run *before*
    /// `PhantomBridge.start` because the `.connected` callback can fire
    /// inside `start`'s suspension. The previous ordering armed the
    /// 30 s watchdog *after* the runtime had already published its
    /// `.connected` frame, so `cancelHandshakeTimeout()` ran on `nil` and
    /// then we promptly armed a fresh watchdog that nobody ever cancelled
    /// — guaranteeing the tunnel was force-killed exactly 30 s after a
    /// successful wake.
    ///
    /// Audit PROV-R2-N07 — also cancel any in-flight `outboundTask` before
    /// the reconnect so we don't keep streaming TUN packets into a dead
    /// PhantomBridge. The replacement loop is spawned right after the new
    /// runtime is up and `setTunnelNetworkSettings` has applied.
    private func forceRuntimeReconnect(reason: String) {
        let (profile, settings, outbound) = withStateLock { () -> (VpnProfile?, TunnelSettings?, Task<Void, Never>?) in
            let captured = outboundTask
            outboundTask = nil
            return (activeProfile, activeSettings, captured)
        }
        guard let profile, let settings else {
            log.warning("forceRuntimeReconnect skipped — no active profile")
            return
        }
        let verbose = withStateLock { verboseLog }
        let runtimeProfile = profileForRuntime(profile: profile, settings: settings)

        Task {
            // PROV-R2-N07 — drain the outbound stream so any in-flight
            // submitInbound calls land in the dying bridge, not the new one.
            outbound?.cancel()
            _ = await outbound?.value

            await PhantomBridge.shared.stop()
            // PROV-R2-R02 — arm the handshake watchdog BEFORE start so a
            // racing `.connected` callback finds a cancellable timer.
            self.armHandshakeTimeout()
            do {
                try await PhantomBridge.shared.start(
                    profile: runtimeProfile,
                    settings: settings,
                    verboseLog: verbose,
                    onStatus: { [weak self] frame in
                        guard let self else { return }
                        self.publishStatusFrame(frame)
                        if frame.state == .connected {
                            self.emitProviderEvent(
                                level: "INF",
                                category: "tunnel",
                                event: "connected",
                                fields: [
                                    "session_secs": String(frame.sessionSecs),
                                    "n_streams": String(frame.nStreams),
                                    "streams_up": String(frame.streamsUp),
                                ]
                            )
                            self.cancelHandshakeTimeout()
                            self.cancelReconnectingWatchdog()
                        } else if frame.state == .reconnecting {
                            self.armReconnectingWatchdog()
                        }
                    },
                    onLog: { [weak self] frame in
                        guard let self else { return }
                        self.appendProviderLog(frame)
                    },
                    onInbound: { [weak self] data in
                        guard let self else { return }
                        let proto = Self.afFamily(forFirstByte: data.first ?? 0)
                        self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: proto)])
                    }
                )
                self.emitProviderEvent(
                    level: "INF",
                    category: "tunnel",
                    event: "reconnect",
                    fields: ["reason": reason]
                )
                // PROV-R2-N07 — start a fresh outbound loop now that the
                // new bridge is live and route settings are in place.
                let replacement: Task<Void, Never> = Task.detached { [weak self] in
                    guard let self else { return }
                    await self.outboundLoop()
                }
                self.withStateLock {
                    self.outboundTask = replacement
                }
            } catch {
                self.cancelHandshakeTimeout()
                self.emitProviderEvent(
                    level: "ERR",
                    category: "tunnel",
                    event: "reconnect_failed",
                    fields: [
                        "reason": reason,
                        "error": error.localizedDescription,
                    ]
                )
            }
        }
    }

    // MARK: - NWPathMonitor (Audit PROV-H2)

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        withStateLock {
            previousPathStatus = nil
            previousPathInterfaces = nil
            pathMonitor = monitor
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func stopPathMonitor() {
        withStateLock {
            pathMonitor?.cancel()
            pathMonitor = nil
            previousPathStatus = nil
            previousPathInterfaces = nil
            // Audit PROV-R2-N04 — drop any pending debounce so a queued
            // path-change reconnect can't fire after the tunnel is gone.
            pathDebounceTask?.cancel()
            pathDebounceTask = nil
        }
    }

    /// Audit PROV-R2-N04 — NWPathMonitor often emits 2-5 updates within a
    /// few hundred ms when interfaces flap (joining/leaving a network,
    /// captive portal probes, the system retrying DHCP). The previous code
    /// kicked a fresh `forceRuntimeReconnect` for each edge, draining
    /// battery and racing the previous reconnect's handshake watchdog.
    /// Coalesce updates onto a single 2 s window: only the last edge in
    /// that window actually triggers a reconnect.
    private func handlePathUpdate(_ path: Network.NWPath) {
        let interfaces: Set<NWInterface.InterfaceType> = [
            .wifi, .cellular, .wiredEthernet, .loopback, .other
        ].filter { path.usesInterfaceType($0) }.reduce(into: Set()) { $0.insert($1) }

        let outcome: (Bool, Bool)? = withStateLock {
            let prevStatus = previousPathStatus
            let prevIfaces = previousPathInterfaces
            previousPathStatus = path.status
            previousPathInterfaces = interfaces

            // First callback — record baseline, don't reconnect.
            guard prevStatus != nil else { return nil }

            let recovered = prevStatus == .unsatisfied && path.status == .satisfied
            let interfaceChanged = prevIfaces != nil && prevIfaces != interfaces
            guard recovered || interfaceChanged else { return nil }
            return (recovered, interfaceChanged)
        }
        guard let (recovered, interfaceChanged) = outcome else { return }

        log.info("path change — debouncing reconnect (recovered=\(recovered) ifaceChanged=\(interfaceChanged))")
        scheduleDebouncedReconnect(reason: recovered ? "path_recovered" : "iface_changed")
    }

    private func scheduleDebouncedReconnect(reason: String) {
        let task = Task<Void, Never> { [weak self] in
            let nanos = Self.pathDebounceSeconds * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.forceRuntimeReconnect(reason: reason)
        }
        let previous = withStateLock { () -> Task<Void, Never>? in
            let prev = pathDebounceTask
            pathDebounceTask = task
            return prev
        }
        previous?.cancel()
    }

    private static func afFamily(forFirstByte byte: UInt8) -> Int32 {
        // IPv4 packets have the version nibble 4 in the high 4 bits; IPv6
        // uses 6. Anything else falls back to IPv4 (matches the historic
        // behaviour but won't drop legitimate IPv6 packets).
        return ((byte >> 4) == 6) ? AF_INET6 : AF_INET
    }

    private func armHandshakeTimeout() {
        // Audit PROV-R2-R01 — install the new task under the state lock so
        // a concurrent `cancelHandshakeTimeout` (e.g. the `.connected`
        // callback racing the post-`start` re-arm) sees one cohesive write.
        let task = Task<Void, Never> { [weak self] in
            let nanos = Self.handshakeTimeoutSeconds * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            // Audit PROV-R2-R02 — defensive double-check: if the runtime
            // already published `.connected` between the timer firing and
            // this branch running, bail. Pairs with the cancel in the
            // `onStatus` `.connected` arm but survives missed cancel races.
            let alreadyConnected = self.withStateLock { self.lastStatusFrame.state == .connected }
            if alreadyConnected { return }
            let err = NSError(
                domain: "GhostStream",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "VPN handshake timed out"]
            )
            self.callStartCompletionOnce(err)
            self.cancelTunnelWithError(err)
        }
        let previous = withStateLock { () -> Task<Void, Never>? in
            let prev = handshakeTimeoutTask
            handshakeTimeoutTask = task
            return prev
        }
        previous?.cancel()
    }

    private func cancelHandshakeTimeout() {
        let task = withStateLock { () -> Task<Void, Never>? in
            let captured = handshakeTimeoutTask
            handshakeTimeoutTask = nil
            return captured
        }
        task?.cancel()
    }

    /// Audit PROV-R2-N02 — armed when the runtime publishes `.reconnecting`
    /// in the `onStatus` callback. If the runtime stays in that state
    /// without advancing to `.connected` or `.error` within
    /// `reconnectingWatchdogSeconds`, we force a hard reconnect ourselves.
    /// Without this watchdog the UI can be stuck on "reconnecting" forever
    /// when the runtime's internal retry loop wedges (e.g. resolver hung,
    /// TLS in CLOSE_WAIT).
    private func armReconnectingWatchdog() {
        let task = Task<Void, Never> { [weak self] in
            let nanos = Self.reconnectingWatchdogSeconds * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            let stillStuck = self.withStateLock { self.lastStatusFrame.state == .reconnecting }
            guard stillStuck else { return }
            self.emitProviderEvent(
                level: "WRN",
                category: "tunnel",
                event: "reconnecting_watchdog",
                fields: ["timeout_secs": String(Self.reconnectingWatchdogSeconds)]
            )
            self.forceRuntimeReconnect(reason: "stuck_reconnecting")
        }
        let previous = withStateLock { () -> Task<Void, Never>? in
            let prev = reconnectingWatchdogTask
            reconnectingWatchdogTask = task
            return prev
        }
        previous?.cancel()
    }

    private func cancelReconnectingWatchdog() {
        let task = withStateLock { () -> Task<Void, Never>? in
            let captured = reconnectingWatchdogTask
            reconnectingWatchdogTask = nil
            return captured
        }
        task?.cancel()
    }

    // MARK: - IPC

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let message: TunnelIpcBridge.Message
        do {
            // Audit IPC-H2 — canonical Codable only. Legacy JSON-key probing
            // and plain UTF-8 string strategies were a foot-gun; e.g. any
            // process able to reach the session could send `"stop"` and
            // tear down the tunnel.
            message = try JSONDecoder().decode(TunnelIpcBridge.Message.self, from: messageData)
        } catch {
            emitProviderEvent(
                level: "WRN",
                category: "ipc",
                event: "request",
                fields: [
                    "op": "decode_failure",
                    "error": error.localizedDescription,
                ]
            )
            let response = TunnelIpcBridge.Response.error("IPC decode failed: \(error.localizedDescription)")
            completionHandler?(try? JSONEncoder().encode(response))
            return
        }

        let opName = ipcOpName(message)
        emitProviderEvent(
            level: "DBG",
            category: "ipc",
            event: "request",
            fields: ["op": opName]
        )

        switch message {
        case .getStatus:
            let response = TunnelIpcBridge.Response.status(currentStatusFrame())
            completionHandler?(try? JSONEncoder().encode(response))
            emitProviderEvent(
                level: "DBG",
                category: "ipc",
                event: "response",
                fields: ["op": opName, "status": "ok"]
            )

        case .subscribeLogs(let sinceMs):
            let filtered = currentLogFrames(sinceMs: sinceMs)
            let response = TunnelIpcBridge.Response.logs(filtered)
            completionHandler?(try? JSONEncoder().encode(response))
            emitProviderEvent(
                level: "DBG",
                category: "ipc",
                event: "response",
                fields: [
                    "op": opName,
                    "status": "ok",
                    "n_logs": String(filtered.count),
                ]
            )

        case .getCurrentProfile:
            // TODO(IPC-M4 / IPC-H5): Implementer C — extend
            // TunnelIpcBridge.Response with `extensionVersion` and the
            // active profile body so the host can sanity-check both wire
            // format and active session identity without a side-band
            // UserDefaults read.
            let response = TunnelIpcBridge.Response.ok
            completionHandler?(try? JSONEncoder().encode(response))
            emitProviderEvent(
                level: "DBG",
                category: "ipc",
                event: "response",
                fields: ["op": opName, "status": "ok"]
            )

        case .updateRoutePolicy(let snapshot):
            // Audit IPC-C2 — serialise concurrent route-policy applies
            // through `routePolicyApplier`. `routeSettingsTask` is the
            // task that owns the current apply; cancelling it requests
            // the older apply to abandon; awaiting its `.value` blocks
            // the new apply until the cancelled run has unwound.
            //
            // Audit PROV-R2-R01 — install the replacement task atomically
            // so a concurrent stopTunnel cannot null-out `routeSettingsTask`
            // between our cancel and our store.
            let previous = withStateLock { routeSettingsTask }
            previous?.cancel()
            let task = Task<Void, Never> { [weak self] in
                _ = await previous?.value
                guard let self else { return }
                if Task.isCancelled { return }
                do {
                    try await self.routePolicyApplier.apply { [weak self] in
                        guard let self else { return }
                        try await self.updateRoutePolicy(snapshot)
                    }
                    let response = TunnelIpcBridge.Response.ok
                    completionHandler?(try? JSONEncoder().encode(response))
                    self.emitProviderEvent(
                        level: "INF",
                        category: "ipc",
                        event: "response",
                        fields: ["op": opName, "status": "ok"]
                    )
                } catch {
                    self.emitProviderEvent(
                        level: "ERR",
                        category: "ipc",
                        event: "response",
                        fields: [
                            "op": opName,
                            "status": "error",
                            "error": error.localizedDescription,
                        ]
                    )
                    let response = TunnelIpcBridge.Response.error(error.localizedDescription)
                    completionHandler?(try? JSONEncoder().encode(response))
                }
            }
            withStateLock {
                routeSettingsTask = task
            }

        case .disconnect:
            // Same ordering as stopTunnel: defer cancel/await of the
            // outbound loop into the Task so the AsyncStream drains
            // before PhantomBridge.stop clears the runtime handlers.
            //
            // Audit PROV-R2-R01 — snapshot + null task references atomically.
            let outbound = withStateLock { () -> Task<Void, Never>? in
                let captured = outboundTask
                outboundTask = nil
                routeSettingsTask?.cancel()
                routeSettingsTask = nil
                handshakeTimeoutTask?.cancel()
                handshakeTimeoutTask = nil
                reconnectingWatchdogTask?.cancel()
                reconnectingWatchdogTask = nil
                pathDebounceTask?.cancel()
                pathDebounceTask = nil
                activeProfile = nil
                activeSettings = nil
                return captured
            }
            stopPathMonitor()
            emitProviderEvent(
                level: "INF",
                category: "tunnel",
                event: "disconnect",
                fields: ["reason": "ipc"]
            )
            Task {
                // Audit CONC-R2-N03 / PROV-R2-N01 — bound each phase so
                // an IPC `.disconnect` can't wedge the extension past the
                // SIGKILL deadline (`PhantomBridge.stop` is now blocking
                // up to 9 s after the Round 1 FFI changes).
                await withTimeout(seconds: 0.5) { @Sendable in
                    outbound?.cancel()
                    _ = await outbound?.value
                }
                // CONC-H1 — clear DNS/routes before the runtime exits.
                await withTimeout(seconds: 1.0) { [weak self] in
                    guard let self else { return }
                    try? await self.setTunnelNetworkSettings(nil)
                }
                await withTimeout(seconds: 1.0) { @Sendable in
                    await PhantomBridge.shared.stop()
                }
                LogFileWriter.shared.flush()
                writeDisconnectedSnapshot()
                let response = TunnelIpcBridge.Response.ok
                completionHandler?(try? JSONEncoder().encode(response))
                emitProviderEvent(
                    level: "DBG",
                    category: "ipc",
                    event: "response",
                    fields: ["op": opName, "status": "ok"]
                )
                // Audit PROV-R2-R03 — do NOT call
                // `cancelTunnelWithError(nil)` here. Calling it after we've
                // already cleared the network settings forces the NE
                // framework to redo teardown a second time (it then calls
                // `stopTunnel(with:.userInitiated, ...)` on us a few ms
                // later), and that second teardown runs against the
                // already-stopped bridge with no profile loaded — racing
                // every snapshot/log frame. The Round 1 IPC commit already
                // emits `.ok` to the host; NE will see `.disconnected`
                // naturally as the settings-clear completes above.
            }
        }
    }

    /// Stable op-label for IPC events. Mirrors the case names in
    /// `TunnelIpcBridge.Message` so `category="ipc"` rows are easy to
    /// filter by op in the Logs tab.
    private func ipcOpName(_ message: TunnelIpcBridge.Message) -> String {
        switch message {
        case .getStatus:          return "get_status"
        case .subscribeLogs:      return "subscribe_logs"
        case .getCurrentProfile:  return "get_current_profile"
        case .updateRoutePolicy:  return "update_route_policy"
        case .disconnect:         return "disconnect"
        }
    }

    // MARK: - Start

    private func startTunnelAsync() async throws {
        let profile: VpnProfile
        do {
            profile = try loadProfile()
        } catch {
            // PROV-H4 — loadProfile threw before the runtime ever started.
            // Make sure both the runtime (in case a previous session left
            // it warm) and NE framework return to a clean state.
            await PhantomBridge.shared.stop()
            self.cancelTunnelWithError(error)
            throw error
        }
        let settings = loadSettings()
        let verbose = readVerboseLogPreference()
        // Audit PROV-R2-R01 — publish the loaded profile/settings/verbose
        // flag under the state lock so a racing wake / path update doesn't
        // observe a half-populated tuple.
        withStateLock {
            activeProfile = profile
            activeSettings = settings
            verboseLog = verbose
        }

        emitProviderEvent(
            level: "INF",
            category: "tunnel",
            event: "start",
            fields: [
                "profile_id": profile.id,
                "profile_name": profile.name,
                "server": profile.serverAddr,
                "sni": profile.serverName,
                "verbose_log": verbose ? "true" : "false",
            ]
        )
        publishStatusFrame(makeStateOnlyFrame(state: .connecting, profile: profile))

        let networkSettings: NEPacketTunnelNetworkSettings
        do {
            networkSettings = try makeNetworkSettings(profile: profile, settings: settings)
        } catch {
            await PhantomBridge.shared.stop()
            self.cancelTunnelWithError(error)
            throw error
        }

        try await setTunnelNetworkSettings(networkSettings)
        emitProviderEvent(
            level: "INF",
            category: "tun",
            event: "created",
            fields: [
                "tun_addr": profile.tunAddr,
                "mtu": "1350",
            ]
        )
        let runtimeProfile = profileForRuntime(profile: profile, settings: settings)

        // PROV-H1/H2 — observe network paths from now on so we can react
        // to interface changes once the tunnel is up.
        startPathMonitor()

        // PROV-C1 — arm the handshake timeout *before* calling start. The
        // timer is cancelled once the first `.connected` frame arrives via
        // `onStatus` below; on expiry it routes through
        // `callStartCompletionOnce` so racing paths still respect the
        // single-shot invariant.
        armHandshakeTimeout()

        // Every completion path below routes through `callStartCompletionOnce`
        // (see `startCompletionLock` docstring) so racing callbacks from
        // the runtime can't trigger the "completionHandler called twice"
        // trap that Apple enforces for `NEPacketTunnelProvider`.
        do {
            try await PhantomBridge.shared.start(
                profile: runtimeProfile,
                settings: settings,
                verboseLog: verbose,
                onStatus: { [weak self] frame in
                    guard let self else { return }
                    // Per ADR 0007 the runtime frame is authoritative — relay
                    // verbatim. No mutation, no enrichment.
                    self.publishStatusFrame(frame)
                    if frame.state == .connected {
                        self.emitProviderEvent(
                            level: "INF",
                            category: "tunnel",
                            event: "connected",
                            fields: [
                                "session_secs": String(frame.sessionSecs),
                                "n_streams": String(frame.nStreams),
                                "streams_up": String(frame.streamsUp),
                            ]
                        )
                        // PROV-C1 — only signal `nil` (success) to NE after
                        // the runtime confirms the handshake is up.
                        self.cancelHandshakeTimeout()
                        self.cancelReconnectingWatchdog()
                        self.callStartCompletionOnce(nil)
                    } else if frame.state == .reconnecting {
                        // PROV-R2-N02 — arm the watchdog so we don't sit in
                        // `.reconnecting` forever if the runtime's retry
                        // loop wedges.
                        self.armReconnectingWatchdog()
                    }
                },
                onLog: { [weak self] frame in
                    guard let self else { return }
                    self.appendProviderLog(frame)
                },
                onInbound: { [weak self] data in
                    guard let self else { return }
                    // PROV-C3 — IPv6 packets must be tagged with AF_INET6 so
                    // packetFlow doesn't silently drop them.
                    let proto = Self.afFamily(forFirstByte: data.first ?? 0)
                    self.packetFlow.writePackets([data], withProtocols: [NSNumber(value: proto)])
                }
            )
        } catch {
            cancelHandshakeTimeout()
            cancelReconnectingWatchdog()
            stopPathMonitor()
            await PhantomBridge.shared.stop()
            emitProviderEvent(
                level: "ERR",
                category: "tunnel",
                event: "error",
                fields: [
                    "phase": "runtime_start",
                    "error": error.localizedDescription,
                ]
            )
            // PROV-H4 — make sure NE framework also returns to a clean state.
            // Re-throw so the outer Task's catch logs + writes the error
            // snapshot. The completion-handler call is funneled through
            // `callStartCompletionOnce` from that catch — not here — so
            // we don't double-fire if `onStatus` already saw `.connected`
            // before the start coroutine threw.
            self.cancelTunnelWithError(error)
            throw error
        }

        emitProviderEvent(
            level: "INF",
            category: "runtime",
            event: "started",
            fields: nil
        )

        // PROV-C1 — DO NOT call `callStartCompletionOnce(nil)` here. The
        // runtime only kicks tokio::spawn'd workers — the handshake hasn't
        // started yet. Signalling success now would tell NE the tunnel is
        // `.connected` immediately, breaking the system status indicator
        // and the host's ability to surface a real handshake failure.
        // Completion fires from the `.connected` onStatus callback above
        // (success) or via `armHandshakeTimeout()` (timeout).

        let task: Task<Void, Never> = Task.detached { [weak self] in
            guard let self else { return }
            await self.outboundLoop()
        }
        withStateLock {
            outboundTask = task
        }
    }

    /// Read the `verbose_log` toggle from the App Group `UserDefaults`
    /// the host writes via `PreferencesStore.verboseLog`. Defaults to
    /// `false` when unset or the suite is unreachable.
    private func readVerboseLogPreference() -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.com.ghoststream.client") else {
            return false
        }
        return defaults.object(forKey: "verbose_log") as? Bool ?? false
    }

    // MARK: - Profile loading

    private func loadProfile() throws -> VpnProfile {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol else {
            throw ProviderError.missingProtocol
        }

        if let profileData = proto.providerConfiguration?["profile"] as? Data {
            do {
                var profile = try JSONDecoder().decode(VpnProfile.self, from: profileData)
                // Privacy fix: the host sanitises certPem/keyPem out of the
                // embedded blob (NE persists `providerConfiguration` in
                // plaintext under /Library/Preferences/...). Hydrate them
                // from the shared Keychain — the same path the legacy
                // profileId-only branch uses below.
                if profile.certPem?.isEmpty != false {
                    profile.certPem = Keychain.get("profile.\(profile.id).cert")
                }
                if profile.keyPem?.isEmpty != false {
                    profile.keyPem = Keychain.get("profile.\(profile.id).key")
                }
                log.info("loaded embedded provider profile id=\(profile.id, privacy: .public)")
                return profile
            } catch {
                throw ProviderError.decodeFailed(error.localizedDescription)
            }
        }

        if let profileId = proto.providerConfiguration?["profileId"] as? String {
            log.info("loading legacy provider profileId=\(profileId, privacy: .public)")
            guard let profile = resolveProfile(id: profileId) else {
                throw ProviderError.profileNotFound(profileId)
            }
            return profile
        }

        throw ProviderError.missingProfile
    }

    private func loadSettings() -> TunnelSettings {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let settingsData = proto.providerConfiguration?["settings"] as? Data,
              let settings = try? JSONDecoder().decode(TunnelSettings.self, from: settingsData)
        else {
            return TunnelSettings()
        }
        return settings
    }

    private func makeNetworkSettings(
        profile: VpnProfile,
        settings: TunnelSettings
    ) throws -> NEPacketTunnelNetworkSettings {
        let (tunIp, subnetMask) = try parseCidr(profile.tunAddr)

        let networkSettings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: tunnelRemoteAddress(for: profile.serverAddr)
        )
        networkSettings.mtu = NSNumber(value: 1350)

        let ipv4 = NEIPv4Settings(addresses: [tunIp], subnetMasks: [subnetMask])
        configureIPv4Routes(ipv4, for: profile, settings: settings)
        networkSettings.ipv4Settings = ipv4

        // PROV-C2 — apply iOS-equivalent IPv6 settings on macOS. Apple
        // requires at least one tunnel IPv6 address before NEIPv6Settings
        // applies; without it the previous empty-addresses path silently
        // ignored the ipv6Killswitch toggle and real IPv6 traffic kept
        // routing through the physical interface. We use the same ULA
        // tunnel address as iOS so unsupported IPv6 traffic is captured
        // and dropped instead of leaking outside the VPN.
        if settings.ipv6Killswitch {
            // TODO(PROV-R2-N08): generate per-profile ULA prefix instead of
            // hardcoding `fd00:6768:6f73:7473::1/64`. Local networks that
            // happen to also use the `fd00:6768::/32` block (unlikely but
            // possible — RFC 4193 ULAs are pseudo-random per-network, and
            // we re-use the same one across every install) would collide.
            // Persist the generated prefix per profile so reconnects stay
            // stable for the duration of an install.
            let ipv6 = NEIPv6Settings(
                addresses: ["fd00:6768:6f73:7473::1"],
                networkPrefixLengths: [64]
            )
            let directIpv6Cidrs = directIpv6RoutesForRouteComputation(settings: settings)
            if shouldTunnelIPv6Traffic(settings: settings, directIpv6Cidrs: directIpv6Cidrs) {
                ipv6.includedRoutes = [NEIPv6Route.default()]
                let excludedRoutes = directIpv6Cidrs.compactMap(route(forIPv6CIDR:))
                if !excludedRoutes.isEmpty {
                    ipv6.excludedRoutes = excludedRoutes
                }
            } else {
                ipv6.excludedRoutes = [NEIPv6Route.default()]
                log.warning("split routing leaves IPv6 outside tunnel because no routeable IPv6 direct rules are available")
            }
            networkSettings.ipv6Settings = ipv6
        } else {
            // killswitch off — still route IPv6 default into the tunnel
            // (so traffic goes through the VPN rather than the clear
            // interface). Without a tunnel address NEIPv6Settings is
            // ignored; supply the ULA so the include actually applies.
            let ipv6 = NEIPv6Settings(
                addresses: ["fd00:6768:6f73:7473::1"],
                networkPrefixLengths: [64]
            )
            ipv6.includedRoutes = [NEIPv6Route.default()]
            networkSettings.ipv6Settings = ipv6
        }

        let dnsServers = profile.dnsServers ?? ["1.1.1.1", "8.8.8.8"]
        let dns = NEDNSSettings(servers: dnsServers)
        if settings.dnsLeakProtection && shouldForceDnsMatchDomains(settings: settings) {
            dns.matchDomains = [""]
        }
        networkSettings.dnsSettings = dns

        return networkSettings
    }

    private func directIpv6RoutesForRouteComputation(settings: TunnelSettings) -> [String] {
        guard settings.routingMode != .global else { return [] }
        var cidrs = settings.manualDirectIpv6Cidrs
        cidrs.append(contentsOf: settings.routePolicy?.manualDirectIpv6Cidrs ?? [])
        let normalized = RoutePolicySnapshot.normalizedIPv6Cidrs(from: cidrs.joined(separator: "\n")).valid
        let routeable = RoutePolicySnapshot.routeableIPv6Cidrs(normalized)
        if normalized.count > RoutePolicySnapshot.maxDirectIPv6RouteCount {
            log.error(
                "too many IPv6 direct routes (\(normalized.count, privacy: .public)); skipping IPv6 exceptions to keep tunnel startup reliable"
            )
        }
        return routeable
    }

    private func shouldTunnelIPv6Traffic(settings: TunnelSettings, directIpv6Cidrs: [String]) -> Bool {
        if settings.routingMode == .global { return true }
        return !directIpv6Cidrs.isEmpty
    }

    private func route(forIPv6CIDR cidr: String) -> NEIPv6Route? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (0...128).contains(prefix)
        else { return nil }
        return NEIPv6Route(
            destinationAddress: String(parts[0]),
            networkPrefixLength: NSNumber(value: prefix)
        )
    }

    private func configureIPv4Routes(
        _ ipv4: NEIPv4Settings,
        for profile: VpnProfile,
        settings: TunnelSettings
    ) {
        let serverDirectCidrs = settings.routePolicy?.serverDirectCidrs ?? []
        let shouldUseSplitRoutes = settings.routingMode != .global
            || !serverDirectCidrs.isEmpty
            || (settings.routePolicy == nil && profile.splitRouting == true)
        guard shouldUseSplitRoutes else {
            ipv4.includedRoutes = [NEIPv4Route.default()]
            ipv4.excludedRoutes = physicalServerExcludedRoutes(settings: settings)
            return
        }

        if let directCountries = profile.directCountries, !directCountries.isEmpty {
            log.warning(
                "split routing has directCountries=\(directCountries.joined(separator: ","), privacy: .public), but no country CIDR bundle is available; applying conservative public IPv4 route set"
            )
        }

        let directCidrs = directCidrsForRouteComputation(profile: profile, settings: settings)
        let routes = PhantomBridge.computeVpnRoutes(directCidrs: directCidrs.joined(separator: "\n"))
            .compactMap { route in
                mask(forIPv4Prefix: route.prefix).map {
                    NEIPv4Route(destinationAddress: route.addr, subnetMask: $0)
                }
            }

        if routes.isEmpty {
            log.error("split routing route computation returned no routes; leaving IPv4 includedRoutes empty")
            ipv4.includedRoutes = []
        } else {
            ipv4.includedRoutes = routes
        }
        ipv4.excludedRoutes = physicalServerExcludedRoutes(settings: settings)
    }

    private func shouldForceDnsMatchDomains(settings: TunnelSettings) -> Bool {
        !(settings.routingMode == .layeredAuto && settings.preserveScopedDns)
    }

    private func directCidrsForRouteComputation(
        profile: VpnProfile,
        settings: TunnelSettings
    ) -> [String] {
        var cidrs = settings.routePolicy?.serverDirectCidrs ?? []
        if settings.routingMode != .global {
            cidrs.append(contentsOf: settings.manualDirectCidrs)
        }
        if settings.routingMode == .layeredAuto {
            cidrs.append(contentsOf: settings.routePolicy?.detectedUpstreamCidrs ?? [])
            cidrs.append(contentsOf: settings.routePolicy?.manualDirectCidrs ?? [])
        }

        let normalized = RoutePolicySnapshot.normalizedCidrs(from: cidrs.joined(separator: "\n")).valid
        if settings.routingMode == .layeredAuto {
            appendProviderLog(
                level: "INF",
                message: "layered routing directCidrs=\(normalized.count) upstream=\(settings.routePolicy?.detectedUpstreamCidrs.count ?? 0) manual=\(settings.manualDirectCidrs.count)"
            )
        }
        return normalized
    }

    private func profileForRuntime(profile: VpnProfile, settings: TunnelSettings) -> VpnProfile {
        guard let endpoint = resolvedServerEndpoint(profile: profile, settings: settings) else {
            return profile
        }

        var runtimeProfile = profile
        runtimeProfile.serverAddr = endpoint
        if let connString = profile.connString,
           let rewritten = rewriteConnStringAuthority(connString, authority: endpoint) {
            runtimeProfile.connString = rewritten
            appendProviderLog(level: "INF", message: "runtime server endpoint pinned to \(endpoint)")
        }
        return runtimeProfile
    }

    private func resolvedServerEndpoint(profile: VpnProfile, settings: TunnelSettings) -> String? {
        guard let serverCidr = settings.routePolicy?.serverDirectCidrs.first,
              let serverIp = serverCidr.split(separator: "/", maxSplits: 1).first,
              IPv4Address(String(serverIp)) != nil
        else { return nil }

        let currentHost = hostPart(of: profile.serverAddr)
        guard IPv4Address(currentHost) == nil else { return nil }

        let port = portPart(of: profile.connString)
            ?? portPart(of: profile.serverAddr)
            ?? "443"
        return "\(serverIp):\(port)"
    }

    private func rewriteConnStringAuthority(_ connString: String, authority: String) -> String? {
        guard connString.hasPrefix("ghs://"),
              let at = connString.firstIndex(of: "@")
        else { return nil }

        let authorityStart = connString.index(after: at)
        guard let queryStart = connString[authorityStart...].firstIndex(of: "?") else {
            return nil
        }

        return String(connString[..<authorityStart])
            + authority
            + String(connString[queryStart...])
    }

    private func physicalServerExcludedRoutes(settings: TunnelSettings) -> [NEIPv4Route] {
        let upstreamCidrs = settings.routingMode == .layeredAuto
            ? (settings.routePolicy?.detectedUpstreamCidrs ?? [])
            : []
        return (settings.routePolicy?.serverDirectCidrs ?? []).compactMap { cidr in
            guard !cidrIsContainedInAny(cidr, containers: upstreamCidrs),
                  let route = route(forCIDR: cidr)
            else { return nil }
            return route
        }
    }

    private func route(forCIDR cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = UInt8(parts[1]),
              let subnetMask = mask(forIPv4Prefix: prefix)
        else { return nil }
        return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: subnetMask)
    }

    private func cidrIsContainedInAny(_ cidr: String, containers: [String]) -> Bool {
        guard let child = ipv4Range(forCIDR: cidr) else { return false }
        return containers.contains { container in
            guard let parent = ipv4Range(forCIDR: container) else { return false }
            return parent.lower <= child.lower && child.upper <= parent.upper
        }
    }

    private func ipv4Range(forCIDR cidr: String) -> (lower: UInt32, upper: UInt32)? {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = UInt32(parts[1]),
              prefix <= 32,
              let ip = ipv4Integer(String(parts[0]))
        else { return nil }

        let hostMask: UInt32 = prefix == 32 ? 0 : (UInt32.max >> prefix)
        let networkMask = ~hostMask
        let lower = ip & networkMask
        return (lower, lower | hostMask)
    }

    private func ipv4Integer(_ address: String) -> UInt32? {
        let octets = address.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var output: UInt32 = 0
        for octet in octets {
            guard let value = UInt32(octet), value <= 255 else { return nil }
            output = (output << 8) | value
        }
        return output
    }

    private func updateRoutePolicy(_ snapshot: RoutePolicySnapshot) async throws {
        // Audit PROV-R2-R01 — read + write the active profile/settings under
        // the state lock so a racing `forceRuntimeReconnect` doesn't see
        // half-mutated settings.
        let prepared: (VpnProfile, TunnelSettings)? = withStateLock {
            guard var settings = activeSettings, let profile = activeProfile else {
                return nil
            }
            settings.routingMode = snapshot.mode
            settings.manualDirectCidrs = snapshot.manualDirectCidrs
            settings.manualDirectIpv6Cidrs = snapshot.manualDirectIpv6Cidrs
            settings.preserveScopedDns = snapshot.preserveScopedDns
            settings.routePolicy = snapshot
            activeSettings = settings
            return (profile, settings)
        }
        guard let (profile, settings) = prepared else {
            throw ProviderError.missingProfile
        }

        // Serialisation of concurrent applies happens at the caller via
        // `routePolicyApplier` (see handleAppMessage `.updateRoutePolicy`).
        let networkSettings = try makeNetworkSettings(profile: profile, settings: settings)
        try await setTunnelNetworkSettings(networkSettings)
        appendProviderLog(
            level: "OK",
            message: "route policy applied hash=\(snapshot.routeHash) upstreamRoutes=\(snapshot.detectedUpstreamCidrs.count)"
        )
    }

    private func resolveProfile(id: String) -> VpnProfile? {
        let defaults = UserDefaults(suiteName: "group.com.ghoststream.client")
        guard
            let data = defaults?.data(forKey: "profiles.json"),
            let profiles = try? JSONDecoder().decode([VpnProfile].self, from: data),
            var profile = profiles.first(where: { $0.id == id })
        else { return nil }

        profile.certPem = Keychain.get("profile.\(id).cert")
        profile.keyPem  = Keychain.get("profile.\(id).key")
        return profile
    }

    // MARK: - Packet loop

    /// Continuously drain TUN packets and forward them to the Rust runtime.
    ///
    /// Implementation note (continuation-leak fix): the previous version
    /// wrapped `packetFlow.readPackets` in a single `withCheckedContinuation`
    /// per iteration. When `outboundTask.cancel()` ran while we were waiting
    /// on `readPackets` (always the case on stopTunnel), the continuation
    /// never resumed — `readPackets` has no cancel API — and Swift logged
    /// `SWIFT TASK CONTINUATION MISUSE: outboundLoop() leaked its
    /// continuation`. The leak left the extension in a half-dead state
    /// where subsequent `startTunnel` requests hung.
    ///
    /// Switching to an `AsyncStream` makes cancellation correct: `for await`
    /// terminates as soon as the parent task is cancelled, the stream
    /// finishes, and any late `readPackets` callback yields into a finished
    /// stream (no-op, no leak).
    private func outboundLoop() async {
        // PROV-H7 — buffer at most 16 batches of pending packets. Packet
        // loss is acceptable under back-pressure (TCP will retransmit);
        // an unbounded buffer would let memory grow without bound while
        // the Rust runtime falls behind, e.g. during a TLS handshake or
        // a brief network stall.
        //
        // Audit PROV-R2-N03 — `scheduleRead`'s `self.packetFlow` capture
        // and the `readPackets` completion closure both retained the
        // Provider strongly. NE bookkeeps active `NEPacketTunnelProvider`
        // instances in process; the strong cycle through `packetFlow`
        // (which references its owning provider) plus the AsyncStream
        // captured the provider for the lifetime of the stream. Once a
        // tunnel restart fired, the old provider was never released —
        // the leak compounded across reconnects until the host process
        // was reaped. Capture `self` weakly here so the AsyncStream and
        // its underlying continuation can drop their references when the
        // stream terminates.
        let packetsStream = AsyncStream<[Data]>(bufferingPolicy: .bufferingNewest(16)) { [weak self] continuation in
            func scheduleRead() {
                guard let strong = self else {
                    continuation.finish()
                    return
                }
                strong.packetFlow.readPackets { packets, _ in
                    let result = continuation.yield(packets)
                    switch result {
                    case .terminated:
                        return
                    default:
                        scheduleRead()
                    }
                }
            }
            scheduleRead()
        }

        for await packets in packetsStream {
            if Task.isCancelled { break }
            for pkt in packets {
                await PhantomBridge.shared.submitInbound(pkt)
            }
        }
    }

    // MARK: - State broadcast

    // IPC-H3 — `vpn.state.v1` UserDefaults channel + its dedicated Darwin
    // notification has no reader (snapshot.json + a single Darwin
    // notification covers both writers and readers). Removed to eliminate
    // the dead path and the duplicate-write that IPC-M4 also flagged
    // (the "connecting" payload was written twice per start).

    private func writeSnapshot(_ frame: StatusFrame) {
        guard let data = try? JSONEncoder().encode(frame) else { return }

        if let defaults = UserDefaults(suiteName: "group.com.ghoststream.client") {
            defaults.set(data, forKey: snapshotPayloadKey)
            defaults.set(Date().timeIntervalSince1970, forKey: snapshotUpdatedAtKey)
            defaults.synchronize()
        }

        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.ghoststream.client")?
            .appendingPathComponent("snapshot.json")
        {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Audit SEC-R2-N04 — the previous flow was
                //   `data.write(to: url, options: .atomic)`
                //   followed by `setAttributes(.posixPermissions: 0o600)`.
                // Between those two steps the freshly-renamed file is
                // visible at 0644 (umask default) — another local user can
                // open it before the chmod completes and read SNI / server
                // IP / tun_addr. Use `atomicWrite` which pre-creates the
                // temp file at 0600 before the final rename so the file is
                // never world-readable in any visible state.
                try atomicWrite(data, to: url, mode: NSNumber(value: 0o600))
            } catch {
                log.error("snapshot write failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            log.error("snapshot container unavailable")
        }

        // Single Darwin notification — consumers re-read snapshot.json.
        DarwinNotifications.post(DarwinNotifications.stateChanged)
    }

    private func writeErrorSnapshot(_ message: String) {
        emitProviderEvent(
            level: "ERR",
            category: "tunnel",
            event: "error",
            fields: ["error": message]
        )
        let frame = StatusFrame(
            state: .error,
            sessionSecs: 0,
            bytesRx: 0,
            bytesTx: 0,
            rateRxBps: 0,
            rateTxBps: 0,
            nStreams: 0,
            streamsUp: 0,
            streamActivity: Array(repeating: 0, count: 16),
            rttMs: nil,
            tunAddr: nil,
            serverAddr: nil,
            sni: nil,
            lastError: message,
            reconnectAttempt: nil,
            reconnectNextDelaySecs: nil
        )
        publishStatusFrame(frame)
    }

    private func writeDisconnectedSnapshot() {
        emitProviderEvent(
            level: "INF",
            category: "tunnel",
            event: "disconnected",
            fields: nil
        )
        publishStatusFrame(.disconnected)
        // Audit PROV-R2-N11 — the in-memory ring buffer survives the
        // disconnect → reconnect cycle because the Provider class is
        // re-used by NE. Without an explicit reset, every `subscribeLogs`
        // for a fresh session re-served all 10k frames from the *previous*
        // tunnel. Clear the buffer here so the host's "Logs" tab starts
        // empty on each new session.
        withStateLock {
            recentLogFrames.removeAll(keepingCapacity: false)
        }
    }

    /// Build a minimal `StatusFrame` carrying only `state` plus the endpoint
    /// identity already known from the profile. Used while connecting (before
    /// the runtime emits its first frame), on disconnect and on hard error.
    /// All telemetry fields stay at their zero/default values — the runtime
    /// owns those numbers per ADR 0007.
    private func makeStateOnlyFrame(state: ConnState, profile: VpnProfile? = nil) -> StatusFrame {
        // Audit PROV-R2-R01 — `activeProfile` may be mutated from a
        // background queue (e.g. `wake`'s reconnect Task or `.disconnect`
        // IPC). Take the snapshot under the state lock when the caller
        // didn't pass an explicit profile.
        let p = profile ?? withStateLock { activeProfile }
        return StatusFrame(
            state: state,
            sessionSecs: 0,
            bytesRx: 0,
            bytesTx: 0,
            rateRxBps: 0,
            rateTxBps: 0,
            nStreams: 0,
            streamsUp: 0,
            streamActivity: Array(repeating: 0, count: 16),
            rttMs: nil,
            tunAddr: p?.tunAddr,
            serverAddr: p?.serverAddr,
            sni: p?.serverName,
            lastError: nil,
            reconnectAttempt: nil,
            reconnectNextDelaySecs: nil
        )
    }

    /// Legacy helper retained for diagnostic call-sites that don't yet
    /// have a category/event mapping. New code should prefer
    /// `emitProviderEvent` which produces a v2 LogFrame.
    private func appendProviderLog(level: String, message: String) {
        let frame = LogFrame(
            tsUnixMs: UInt64(Date().timeIntervalSince1970 * 1000),
            level: level,
            msg: message
        )
        appendProviderLog(frame)
    }

    /// ADR 0008 — the canonical Provider-side event emitter. Builds a
    /// structured v2 `LogFrame` (category + fields), stamps it onto the
    /// ring buffer, mirrors it to OSLog with a category-aware logger, and
    /// hands it to `LogFileWriter` for NDJSON persistence.
    private func emitProviderEvent(
        level: String,
        category: String,
        event: String,
        fields: [String: String]?
    ) {
        var prepared: [String: String] = [:]
        if let fields {
            for (k, v) in fields {
                prepared[k] = v
            }
        }
        prepared["event"] = event

        let summary: String
        if !prepared.isEmpty {
            let pairs = prepared.keys.sorted()
                .map { "\($0)=\(prepared[$0] ?? "")" }
                .joined(separator: " ")
            summary = pairs
        } else {
            summary = event
        }

        let frame = LogFrame.structured(
            level: level,
            category: category,
            msg: summary,
            fields: prepared
        )
        appendProviderLog(frame)
    }

    private func publishStatusFrame(_ frame: StatusFrame) {
        withStateLock {
            lastStatusFrame = frame
        }
        writeSnapshot(frame)
    }

    private func currentStatusFrame() -> StatusFrame {
        withStateLock { lastStatusFrame }
    }

    private func currentLogFrames(sinceMs: UInt64) -> [LogFrame] {
        let filtered = withStateLock { recentLogFrames.filter { $0.tsUnixMs > sinceMs } }
        // Audit IPC-H1 — the first poll after the host subscribes uses
        // `sinceMs == 0` which would otherwise return up to
        // `maxRecentLogFrames` (10 000) frames in one XPC reply. Cap to
        // the most recent 500; the client advances `sinceMs` on each
        // poll, so backlog beyond that catches up across subsequent
        // round-trips without slowing the first response.
        let maxFrames = 500
        if filtered.count > maxFrames {
            return Array(filtered.suffix(maxFrames))
        }
        return filtered
    }

    /// Maximum number of `LogFrame`s retained in the in-memory ring
    /// buffer. ADR 0008 raises this from 200 → 10 000 so the UI can
    /// surface a meaningful trace without round-tripping to disk.
    private static let maxRecentLogFrames = 10_000

    private func appendProviderLog(_ frame: LogFrame) {
        withStateLock {
            recentLogFrames.append(frame)
            if recentLogFrames.count > Self.maxRecentLogFrames {
                recentLogFrames.removeFirst(recentLogFrames.count - Self.maxRecentLogFrames)
            }
        }

        // Mirror to OSLog for live `log stream` consumers — one logger
        // per category keeps the predicate filter clean. The level
        // mapping follows ADR 0008 §3.
        //
        // PRIVACY: OSLog persists into sysdiagnose bundles and (with the
        // Analytics & Improvements toggle on) iCloud Analytics. Categories
        // whose `msg` typically carries server IP, SNI, tun_addr, or
        // stream identifiers must mask their payload — `privacy: .private`
        // redacts to `<private>` in Console.app and sysdiagnose so the
        // identifier never reaches Apple. The msg is still preserved
        // verbatim in our in-process LogFileWriter NDJSON for engineering
        // use; this only affects the OSLog mirror.
        let logger = osLogPool.logger(for: frame.category)
        let level = Self.osLogType(for: frame.level)
        if Self.isSensitiveOSLogCategory(frame.category) {
            logger.log(level: level, "\(frame.msg, privacy: .private)")
        } else {
            logger.log(level: level, "\(frame.msg, privacy: .public)")
        }

        // Persist to the NDJSON runtime log. Non-blocking — the writer
        // queue absorbs back-pressure for us.
        LogFileWriter.shared.append(frame)
    }

    /// Categories whose `msg` regularly carries network identifiers
    /// (server IP/host, SNI, tun_addr, stream id). These get redacted
    /// when mirrored to OSLog so sysdiagnose bundles and iCloud Analytics
    /// never see the raw value. The full payload still lives in the
    /// in-process NDJSON runtime log under `~/Library/Logs/GhostStream/`.
    private static func isSensitiveOSLogCategory(_ category: String?) -> Bool {
        guard let category = category?.lowercased() else { return false }
        switch category {
        case "tunnel", "handshake", "network", "stream":
            return true
        default:
            return false
        }
    }

    private static func osLogType(for level: String) -> OSLogType {
        switch level.uppercased() {
        case "ERR", "ERROR":
            return .fault
        case "WRN", "WARN", "WARNING":
            return .error
        case "INF", "INFO", "OK":
            return .info
        case "DBG", "DEBUG", "TRC", "TRACE":
            return .debug
        default:
            return .info
        }
    }

    /// Audit CONC-R2-N03 / PROV-R2-N01 — bound an async operation by a
    /// wall-clock budget. macOS 15 Sequoia gives `stopTunnel` ~5 s before
    /// the system SIGKILLs the extension; chained steps like
    /// `await PhantomBridge.shared.stop()` (up to 9 s after the Round 1
    /// FFI changes) and `setTunnelNetworkSettings(nil)` (1-3 s in the
    /// wild) would each blow that deadline alone. Wrap each phase so we
    /// at worst miss the tail of teardown — but always return control to
    /// the `completionHandler` before the kill timer fires.
    ///
    /// Returns the operation's result, or `nil` if the timeout fired
    /// first. The losing branch is cancelled but Swift's structured
    /// concurrency may need a moment to unwind it — the caller should
    /// treat the operation as best-effort once `nil` comes back.
    @discardableResult
    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ op: @Sendable @escaping () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                let nanos = UInt64(seconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Audit SEC-R2-N04 — write `data` to `url` so that the file's
    /// permissions are bounded to `mode` for the entire visible lifetime.
    ///
    /// The naive pattern (`data.write(to: url, options: .atomic)` followed by
    /// `setAttributes(.posixPermissions: 0o600)`) leaves a TOCTOU window
    /// where another process can `open(url, O_RDONLY)` before the chmod
    /// completes. We pre-create the temp file with the target mode (via
    /// `createFile(attributes:)`) and only then atomically rename it onto
    /// the destination — never publishing an over-permissive view of the
    /// payload to other local users.
    private func atomicWrite(
        _ data: Data,
        to url: URL,
        mode: NSNumber = NSNumber(value: 0o600)
    ) throws {
        let tempURL = url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")

        let created = FileManager.default.createFile(
            atPath: tempURL.path,
            contents: nil,
            attributes: [.posixPermissions: mode]
        )
        guard created else {
            throw NSError(
                domain: "GhostStream.atomicWrite",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "createFile failed at \(tempURL.path)"]
            )
        }

        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Helpers

    private enum ProviderError: LocalizedError {
        case missingProtocol
        case missingProfile
        case profileNotFound(String)
        case decodeFailed(String)
        case badTunAddr(String)

        var errorDescription: String? {
            switch self {
            case .missingProtocol:         return "protocolConfiguration missing"
            case .missingProfile:          return "providerConfiguration['profile'] or ['profileId'] missing"
            case .profileNotFound(let id): return "Profile not found: \(id)"
            case .decodeFailed(let m):     return "providerConfiguration decode failed: \(m)"
            case .badTunAddr(let s):       return "Invalid tunAddr CIDR: \(s)"
            }
        }
    }

    private func parseCidr(_ cidr: String) throws -> (String, String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              prefix >= 0, prefix <= 32
        else {
            throw ProviderError.badTunAddr(cidr)
        }
        let ip = String(parts[0])
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        let octets = [(mask >> 24) & 0xFF, (mask >> 16) & 0xFF, (mask >> 8) & 0xFF, mask & 0xFF]
        return (ip, octets.map { String($0) }.joined(separator: "."))
    }

    private func mask(forIPv4Prefix prefix: UInt8) -> String? {
        guard prefix <= 32 else { return nil }
        guard prefix > 0 else { return "0.0.0.0" }
        let mask = UInt32.max << (32 - UInt32(prefix))
        let octets = [(mask >> 24) & 0xFF, (mask >> 16) & 0xFF, (mask >> 8) & 0xFF, mask & 0xFF]
        return octets.map { String($0) }.joined(separator: ".")
    }

    private func hostPart(of addr: String) -> String {
        if let lastColon = addr.lastIndex(of: ":"),
           addr.firstIndex(of: ":") == lastColon {
            return String(addr[..<lastColon])
        }
        return addr
    }

    private func portPart(of addr: String?) -> String? {
        guard let addr else { return nil }
        let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("["),
           let close = trimmed.firstIndex(of: "]") {
            let afterClose = trimmed.index(after: close)
            guard afterClose < trimmed.endIndex,
                  trimmed[afterClose] == ":"
            else { return nil }
            let portStart = trimmed.index(after: afterClose)
            guard portStart < trimmed.endIndex else { return nil }
            let port = String(trimmed[portStart...])
            return UInt16(port) == nil ? nil : port
        }

        guard let colon = trimmed.lastIndex(of: ":"),
              trimmed[..<colon].firstIndex(of: ":") == nil
        else { return nil }

        let port = String(trimmed[trimmed.index(after: colon)...])
        return UInt16(port) == nil ? nil : port
    }

    private func tunnelRemoteAddress(for addr: String) -> String {
        let host = hostPart(of: addr)
        if IPv4Address(host) != nil || IPv6Address(host) != nil {
            return host
        }
        return "127.0.0.1"
    }
}

/// Lazy pool of `os.Logger`s, one per logical category. Mirrors LogFrame
/// events to the unified Apple logging facility so `log stream
/// --predicate 'subsystem == "com.ghoststream.client.tunnel"'` lets a
/// developer follow events live without parsing the runtime log file.
private final class OSLogCategoryPool {
    private let subsystem = "com.ghoststream.client.tunnel"
    private let lock = NSLock()
    private var cache: [String: Logger] = [:]

    func logger(for category: String?) -> Logger {
        let key = category?.isEmpty == false ? category! : "uncategorized"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        let logger = Logger(subsystem: subsystem, category: key)
        cache[key] = logger
        lock.unlock()
        return logger
    }
}

/// Audit IPC-C2 — serialises concurrent `updateRoutePolicy` invocations.
/// Actor isolation guarantees that any `apply { ... }` closure runs to
/// completion (or throws) before the next queued closure begins. Without
/// this two `setTunnelNetworkSettings` could race and leave the route
/// table in an inconsistent state on rapid Upstream Monitor toggles.
private actor RoutePolicyApplier {
    func apply(_ work: @Sendable () async throws -> Void) async throws {
        try await work()
    }
}
