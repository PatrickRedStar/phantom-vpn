import SwiftUI

struct ConnectButton: View {
    let state: VpnState
    let action: () -> Void

    @State private var pulse = false

    private var bgColor: Color {
        switch state {
        case .connected: return .greenConnected
        case .connecting, .disconnecting: return .accentPurple
        case .error: return .redError
        case .disconnected: return .accentPurple
        }
    }

    private var icon: String {
        switch state {
        case .connected: return "power.circle.fill"
        case .connecting, .disconnecting: return "arrow.triangle.2.circlepath.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .disconnected: return "power.circle.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(bgColor.opacity(0.2))
                    .frame(width: 146, height: 146)
                    .scaleEffect(pulse ? 1.08 : 0.95)
                    .opacity(pulse ? 0.25 : 0.5)
                    .animation(
                        state == .connecting || state == .disconnecting
                            ? .easeInOut(duration: 1).repeatForever(autoreverses: true)
                            : .default,
                        value: pulse
                    )
                Circle()
                    .fill(bgColor)
                    .frame(width: 122, height: 122)
                Image(systemName: icon)
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .onAppear {
            pulse = true
        }
    }
}
