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
        case subscribeLogs(sinceMs: UInt64)
        case getCurrentProfile
        case disconnect
    }

    /// Responses the extension returns to the host app.
    public enum Response: Codable {
        case status(StatusFrame)
        case logs([LogFrame])
        case profile(VpnProfile?)
        case ok
    }

    // MARK: - State

    private weak var session: NETunnelProviderSession?

    // MARK: - Init

    public init(session: NETunnelProviderSession?) {
        self.session = session
    }

    // MARK: - Public API

    /// Sends a message to the active `PacketTunnelProvider` and awaits its response.
    ///
    /// - Throws: `IpcError.noSession` if no session is attached,
    ///   `IpcError.badResponse` if the extension returns undecodable data,
    ///   or any error thrown by `sendProviderMessage`.
    public func send(_ message: Message) async throws -> Response {
        guard let session else { throw IpcError.noSession }
        let data = try JSONEncoder().encode(message)
        return try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(data) { responseData in
                    if let d = responseData,
                       let response = try? JSONDecoder().decode(Response.self, from: d) {
                        cont.resume(returning: response)
                    } else {
                        cont.resume(throwing: IpcError.badResponse)
                    }
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

/// Errors specific to the IPC bridge.
public enum IpcError: Error {
    /// No `NETunnelProviderSession` is associated with this bridge.
    case noSession
    /// The extension returned data that could not be decoded as `Response`.
    case badResponse
}
