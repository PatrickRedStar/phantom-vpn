import Foundation
import NetworkExtension

/// Wraps `NETunnelProviderSession.sendProviderMessage` for host app ↔ extension IPC.
///
/// The host app creates a `TunnelIpcBridge` with the active session and uses it
/// to query live status, stream logs, or request a disconnect without going
/// through the NEVPNManager layer.
@MainActor
public final class TunnelIpcBridge {

    // MARK: - Message / Response types

    /// Messages the host app can send to the PacketTunnelProvider extension.
    public enum Message: Codable {
        case getStatus
        /// `sinceUs` — микросекундный курсор (`LogFrame.timestampUs`).
        /// Раньше поле было миллисекундным (`sinceMs`): при нескольких
        /// фреймах в одну мс строгий `>` терял хвост той же миллисекунды.
        /// Host и extension шипятся вместе, смена ключа безопасна —
        /// рассинхрон версий даёт декод-ошибку и штатный error-ответ.
        case subscribeLogs(sinceUs: UInt64)
        case getCurrentProfile
        case updateRoutePolicy(RoutePolicySnapshot)
        case disconnect
    }

    /// Responses the extension returns to the host app.
    public enum Response: Codable {
        case status(StatusFrame)
        case logs([LogFrame])
        // TODO(IPC-H5): provider currently answers `.getCurrentProfile` with
        //   `.ok` instead of `.profile(...)`. Owned by Implementer A — see
        //   `apps/macos/PacketTunnelExtension/PacketTunnelProvider.swift:394`.
        //   Leave the case in place so host parsers stay forward-compatible
        //   once the provider is fixed.
        case profile(VpnProfile?)
        case ok
        case error(String)
    }

    // MARK: - State

    private let session: NETunnelProviderSession?

    // MARK: - Init

    public init(session: NETunnelProviderSession?) {
        self.session = session
    }

    // MARK: - Public API

    /// Sends a message to the active `PacketTunnelProvider` and awaits its response.
    ///
    /// Ограничено `timeout` (по умолчанию 10 с): `sendProviderMessage`
    /// вызывает completion только когда провайдер ответит — если тот
    /// потерял ответ (или завис), continuation раньше висла вечно и
    /// вызывающий поллер (UpstreamVpnMonitor / TunnelLogStore) замирал
    /// до перезапуска приложения.
    ///
    /// - Throws: `IpcError.noSession` if no session is attached,
    ///   `IpcError.badResponse` if the extension returns undecodable data,
    ///   `IpcError.timeout` if the provider does not answer in time,
    ///   or any error thrown by `sendProviderMessage`.
    public func send(_ message: Message, timeout: TimeInterval = 10) async throws -> Response {
        guard let session else { throw IpcError.noSession }
        let data = try JSONEncoder().encode(message)
        return try await withCheckedThrowingContinuation { cont in
            let completion = SingleResume(cont)
            do {
                try session.sendProviderMessage(data) { responseData in
                    if let d = responseData,
                       let response = try? JSONDecoder().decode(Response.self, from: d) {
                        completion.resume(.success(response))
                    } else {
                        completion.resume(.failure(IpcError.badResponse))
                    }
                }
            } catch {
                completion.resume(.failure(error))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                completion.resume(.failure(IpcError.timeout))
            }
        }
    }
}

/// Гарантирует ровно один resume у continuation при гонке
/// «ответ провайдера vs таймаут». Тот же паттерн, что
/// `ServerResolveCompletion` в UpstreamVpnRouteDetector.
private final class SingleResume: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<TunnelIpcBridge.Response, Error>

    init(_ continuation: CheckedContinuation<TunnelIpcBridge.Response, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<TunnelIpcBridge.Response, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}

/// Errors specific to the IPC bridge.
public enum IpcError: Error {
    /// No `NETunnelProviderSession` is associated with this bridge.
    case noSession
    /// The extension returned data that could not be decoded as `Response`.
    case badResponse
    /// The provider did not answer within the allotted timeout.
    case timeout
}
