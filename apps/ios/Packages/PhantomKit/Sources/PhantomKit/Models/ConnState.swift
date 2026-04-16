import Foundation

public enum ConnState: String, Codable, Equatable {
    case disconnected
    case connecting
    case reconnecting
    case connected
    case error

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
