// PhantomBridge — single actor-isolated bridge to the PhantomCore Rust FFI.
// Both the host app (GhostStream) and the PacketTunnelProvider extension
// import this via PhantomKit instead of each maintaining their own copy.

import Foundation

// MARK: - C FFI declarations
// Symbols are provided by PhantomCore.xcframework linked in the host target.
// @_silgen_name tells the Swift compiler the symbols exist without a header.

@_silgen_name("phantom_runtime_start")
private func c_phantom_runtime_start(
    _ cfg_json: UnsafePointer<CChar>?,
    _ settings_json: UnsafePointer<CChar>?,
    /// ADR 0008: when `true`, Rust runtime applies `RUST_LOG=trace`
    /// (overriding build defaults but yielding to `GHOSTSTREAM_LOG` env).
    _ verbose_log: Bool,
    _ status_cb: @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void,
    _ log_cb: @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void,
    _ outbound_cb: @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?) -> Void,
    _ ctx: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("phantom_runtime_submit_inbound")
private func c_phantom_runtime_submit_inbound(
    _ buf: UnsafePointer<UInt8>?,
    _ len: Int
) -> Int32

@_silgen_name("phantom_runtime_stop")
private func c_phantom_runtime_stop() -> Int32

/// Register the release callback Rust invokes from inside
/// `phantom_runtime_stop` *after* the supervisor and forwarder tasks have
/// fully drained. This is the only safe moment to balance the
/// `Unmanaged.passRetained` we did in `start()` — see FFI-C1 in
/// 2026-05-17 macOS bug-hunt.
@_silgen_name("phantom_runtime_set_release_cb")
private func c_phantom_runtime_set_release_cb(
    _ cb: @convention(c) (UnsafeMutableRawPointer?) -> Void
)

@_silgen_name("phantom_parse_conn_string")
private func c_phantom_parse_conn_string(
    _ input: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_compute_vpn_routes")
private func c_phantom_compute_vpn_routes(
    _ cidrs_path: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<CChar>?

@_silgen_name("phantom_free_string")
private func c_phantom_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

/// One-shot install of the global `release_ctx` trampoline. Rust accepts
/// only the first registration; subsequent calls are silently ignored.
/// Run this exactly once at module-load time via a dispatch-once guard so
/// both the host app and the extension end up sharing one trampoline.
private let releaseCtxInstaller: Void = {
    c_phantom_runtime_set_release_cb { ctx in
        guard let ctx else { return }
        // Balances the `Unmanaged.passRetained` performed in `start()`.
        // `release()` decrements the retain count; the underlying
        // `BridgeContext` is freed when the actor itself drops the
        // matching `contextBox` reference.
        Unmanaged<BridgeContext>.fromOpaque(ctx).release()
    }
    return ()
}()

// MARK: - Errors

public enum BridgeError: Error {
    case startFailed(Int32)
    case encoding
    case nullReturn
}

// MARK: - Context box (retains the actor across C callbacks)

private final class BridgeContext: @unchecked Sendable {
    let bridge: PhantomBridge
    /// Горячий путь: inbound-пакеты доставляются Swift-стороне НАПРЯМУЮ
    /// с Rust-потока форвардера, без прыжка на актор. Прежний вариант
    /// (`Task { await bridge.handleInbound(...) }`) ставил каждый пакет в
    /// очередь актора, где он конкурировал со status/log-колбэками и
    /// synchronous I/O — под лог-нагрузкой data-path голодал («интернет
    /// пропадает» при открытой вкладке логов). Колбэк обязан быть
    /// thread-safe: оба провайдера зовут только `packetFlow.writePackets`
    /// (потокобезопасен по контракту NE).
    let onInbound: (Data) -> Void
    init(bridge: PhantomBridge, onInbound: @escaping (Data) -> Void) {
        self.bridge = bridge
        self.onInbound = onInbound
    }
}

// MARK: - PhantomBridge actor

/// Single actor-isolated bridge to the PhantomCore Rust FFI.
///
/// Call `start(profile:settings:onStatus:onLog:onInbound:)` to launch the
/// tunnel. The three callbacks are invoked on an unspecified thread from the
/// Rust side; the actor re-dispatches them onto itself so all state access is
/// serialised.
///
/// Both the host app and `PacketTunnelProvider` import this from PhantomKit —
/// there is no longer a duplicated `PhantomBridge.swift` in each target.
public actor PhantomBridge {
    public static let shared = PhantomBridge()

    public typealias StatusCallback  = (StatusFrame) -> Void
    public typealias LogCallback     = (LogFrame) -> Void
    public typealias InboundCallback = (Data) -> Void

    private var statusHandler:  StatusCallback?
    private var logHandler:     LogCallback?

    /// Retained across the tunnel lifetime to prevent the context from
    /// being deallocated while Rust still holds a raw pointer to it.
    private var contextBox: AnyObject?

    /// Opaque pointer handed to Rust via `Unmanaged.passRetained.toOpaque`.
    /// Kept here purely for diagnostics — the actual release is performed
    /// by the global trampoline that Rust invokes from inside
    /// `phantom_runtime_stop`. FFI-C1.
    private var opaqueCtx: UnsafeMutableRawPointer?

    private init() {}

    // MARK: - Public API

    /// Starts the Rust tunnel runtime.
    ///
    /// - Parameters:
    ///   - profile: Active VPN profile (conn string + server metadata).
    ///   - settings: Runtime settings forwarded to Rust.
    ///   - verboseLog: ADR 0008 — when `true`, Rust applies TRACE-level
    ///     filter unless overridden by env `GHOSTSTREAM_LOG`. Defaults
    ///     to `false`; the host reads `UserDefaults.verbose_log` and
    ///     passes it here at tunnel start.
    ///   - onStatus: Invoked on each `StatusFrame` from Rust.
    ///   - onLog: Invoked on each `LogFrame` from Rust.
    ///   - onInbound: Invoked with each raw inbound IP packet from Rust.
    /// - Throws: `BridgeError.encoding` on JSON serialisation failure,
    ///   `BridgeError.startFailed` if the Rust side returns a non-zero code.
    public func start(
        profile: VpnProfile,
        settings: TunnelSettings,
        verboseLog: Bool = false,
        onStatus:  @escaping StatusCallback,
        onLog:     @escaping LogCallback,
        onInbound: @escaping InboundCallback
    ) throws {
        // Install the global release-ctx trampoline once. Lazily evaluated
        // via the `let releaseCtxInstaller: Void` constant — first access
        // performs the registration, subsequent accesses are zero-cost.
        _ = releaseCtxInstaller

        statusHandler  = onStatus
        logHandler     = onLog

        guard let connStr = profile.connString ?? ConnStringBuilder.build(from: profile),
              !connStr.isEmpty
        else {
            throw BridgeError.encoding
        }

        // FFI-SIZE fix (июль 2026): рантайм читает из TunnelSettings только
        // dns_leak_protection / ipv6_killswitch / auto_reconnect / streams /
        // dpi_recycle_*. Вся маршрутизация (includedRoutes, routePolicy,
        // manual CIDR) применяется на Swift-стороне через
        // NEPacketTunnelNetworkSettings — Rust её игнорирует. Но раньше
        // полный `settings` с `routePolicy.detectedUpstreamCidrs` (сотни
        // сырых маршрутов Cisco в layeredAuto, ~10 КБ) ехал в cfg_json, а
        // `phantom_runtime_start` читает его через cstr_to_str_bounded с
        // потолком MAX_FFI_CSTR_LEN (16 КБ) → при большом split-include
        // Cisco cfg превышал лимит → ERR_BAD_CONFIG → туннель не стартовал
        // (route-count-зависимый отказ). Отправляем рантайму облегчённую
        // проекцию без routing-балласта.
        let runtimeSettings = TunnelSettings(
            dnsLeakProtection: settings.dnsLeakProtection,
            ipv6Killswitch: settings.ipv6Killswitch,
            autoReconnect: settings.autoReconnect,
            routingMode: settings.routingMode,
            manualDirectCidrs: [],
            manualDirectIpv6Cidrs: [],
            preserveScopedDns: settings.preserveScopedDns,
            routePolicy: nil,
            streams: settings.streams
        )

        let connProfile = ConnectProfile(
            name: profile.name,
            connString: connStr,
            settings: runtimeSettings
        )

        guard
            let cfgData  = try? JSONEncoder().encode(connProfile),
            let cfgStr   = String(data: cfgData, encoding: .utf8),
            let setData  = try? JSONEncoder().encode(runtimeSettings),
            let setStr   = String(data: setData, encoding: .utf8)
        else {
            throw BridgeError.encoding
        }

        let box = BridgeContext(bridge: self, onInbound: onInbound)
        // FFI-C1: keep a Swift-side strong ref so the box stays alive even
        // if Rust somehow returned without invoking release_ctx. The
        // `passRetained` below bumps the Unmanaged retain count to +1; the
        // matching release happens inside the release trampoline that
        // Rust invokes from `phantom_runtime_stop`.
        contextBox = box
        let ctx = Unmanaged.passRetained(box).toOpaque()
        opaqueCtx = ctx

        let rc = cfgStr.withCString { cfgPtr in
            setStr.withCString { setPtr in
                c_phantom_runtime_start(
                    cfgPtr,
                    setPtr,
                    verboseLog,
                    { buf, len, ctx in
                        guard let ctx, let buf, len > 0 else { return }
                        let data = Data(bytes: buf, count: len)
                        let box = Unmanaged<BridgeContext>.fromOpaque(ctx).takeUnretainedValue()
                        Task { await box.bridge.handleStatus(data: data, from: box) }
                    },
                    { buf, len, ctx in
                        guard let ctx, let buf, len > 0 else { return }
                        let data = Data(bytes: buf, count: len)
                        let box = Unmanaged<BridgeContext>.fromOpaque(ctx).takeUnretainedValue()
                        Task { await box.bridge.handleLog(data: data, from: box) }
                    },
                    { buf, len, ctx in
                        guard let ctx, let buf, len > 0 else { return }
                        let data = Data(bytes: buf, count: len)
                        let box = Unmanaged<BridgeContext>.fromOpaque(ctx).takeUnretainedValue()
                        // Прямая доставка с Rust-потока — см. BridgeContext.onInbound.
                        box.onInbound(data)
                    },
                    ctx
                )
            }
        }

        guard rc == 0 else {
            // FFI-C1 (start failed): Rust never installed the runtime so it
            // won't invoke release_ctx for this ctx. Balance the retain here
            // synchronously to avoid leaking the BridgeContext on start
            // errors (bad config, already-running collision, etc.).
            Unmanaged<BridgeContext>.fromOpaque(ctx).release()
            opaqueCtx = nil
            contextBox = nil
            throw BridgeError.startFailed(rc)
        }
    }

    /// Submits a raw outbound IP packet into the Rust tunnel.
    /// Drops silently if the packet is empty or the Rust side is not ready.
    /// nonisolated: чистый FFI-вызов без общего состояния актора.
    /// Каждый outbound-пакет раньше вставал в очередь актора и ждал,
    /// пока разгребутся status/log-задачи.
    public nonisolated func submitInbound(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = c_phantom_runtime_submit_inbound(
                base.assumingMemoryBound(to: UInt8.self),
                ptr.count
            )
        }
    }

    /// Stops the Rust tunnel runtime and clears all callbacks.
    ///
    /// FFI-C1/C2/C3: `c_phantom_runtime_stop` is now a synchronous barrier.
    /// It signals the supervisor, joins all forwarder tasks (with a 5 s
    /// supervisor timeout + 2 s per-forwarder timeout, abort + join after
    /// that), and finally invokes the registered release trampoline to
    /// balance the `passRetained` we did in `start()`. If the runtime could
    /// not be joined cleanly Rust skips the release: the box stays alive on
    /// its Unmanaged retain (a deliberate leak), so late callbacks hit valid
    /// memory and are dropped by the `contextBox` identity check.
    public func stop() {
        _ = c_phantom_runtime_stop()
        statusHandler  = nil
        logHandler     = nil
        // The release trampoline (installed once at module load) has
        // already balanced our `passRetained` retain by the time
        // `c_phantom_runtime_stop` returned. Clear our Swift-side strong
        // references so the BridgeContext can deallocate.
        opaqueCtx = nil
        contextBox = nil
    }

    // MARK: - Static helpers (no tunnel state required)

    /// Parses a `ghs://` connection string.
    /// Returns nil on any parse error.
    public static func parseConnString(_ input: String) -> ParsedConnConfig? {
        let raw: UnsafeMutablePointer<CChar>? = input.withCString { c_phantom_parse_conn_string($0) }
        guard let raw else { return nil }
        defer { c_phantom_free_string(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ParsedConnConfig.self, from: data)
    }

    /// Computes inverted VPN routes for split-routing.
    /// `directCidrs` is newline-separated CIDR text.
    /// Returns `[]` on any failure.
    public static func computeVpnRoutes(directCidrs: String) -> [IPRoute] {
        let raw: UnsafeMutablePointer<CChar>? = directCidrs.withCString { c_phantom_compute_vpn_routes($0) }
        guard let raw else { return [] }
        defer { c_phantom_free_string(raw) }
        let json = String(cString: raw)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([IPRoute].self, from: data)) ?? []
    }

    // MARK: - Private callback dispatchers

    // `box !== contextBox` — колбэк от прошлой сессии, контекст которой Rust
    // не смог дожать на stop и оставил утечкой: в текущую сессию не пускаем.

    private func handleStatus(data: Data, from box: BridgeContext) {
        guard box === contextBox,
              let frame = try? JSONDecoder().decode(StatusFrame.self, from: data) else { return }
        statusHandler?(frame)
    }

    private func handleLog(data: Data, from box: BridgeContext) {
        guard box === contextBox,
              let frame = try? JSONDecoder().decode(LogFrame.self, from: data) else { return }
        logHandler?(frame)
    }
}

// MARK: - Supporting types

/// Conn-string parser output. Fields match `parse_conn_string` in
/// `crates/client-common/src/helpers.rs`.
public struct ParsedConnConfig: Codable {
    public let serverAddr: String
    public let serverName: String
    public let tunAddr: String
    public let certPem: String
    public let keyPem: String

    private enum CodingKeys: String, CodingKey {
        case serverAddr = "server_addr"
        case serverName = "server_name"
        case tunAddr = "tun_addr"
        case certPem = "cert_pem"
        case keyPem = "key_pem"
    }
}

/// A single split-routing route entry.
public struct IPRoute: Codable {
    public let addr: String
    public let prefix: UInt8

    private enum CodingKeys: String, CodingKey {
        case addr
        case prefix
    }
}
