import Foundation

public enum ConnState: String, Codable, Equatable {
    case disconnected
    case connecting
    case reconnecting
    case connected
    case error

    /// Custom decoder so a newer Rust runtime variant doesn't poison the
    /// whole `StatusFrame` decode and freeze status reporting. Unknown raw
    /// values land in `.error` — the closest semantically honest fallback
    /// (the UI already treats `.error` as a degraded terminal state).
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ConnState(rawValue: raw) ?? .error
    }

    public func asUiWord() -> String {
        switch self {
        case .disconnected:  return String(localized: "connstate.dormant", bundle: .module)
        case .connecting:    return String(localized: "connstate.handshaking", bundle: .module)
        case .reconnecting:  return String(localized: "connstate.regrouping", bundle: .module)
        case .connected:     return String(localized: "connstate.transmitting", bundle: .module)
        case .error:         return String(localized: "connstate.severed", bundle: .module)
        }
    }
}
