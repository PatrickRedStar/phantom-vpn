//
//  ProfileCard.swift
//  GhostStream
//
//  Tall card representing a single VPN profile in the Settings list.
//  Shows name, server address, ping indicator and subscription expiry.
//

import PhantomKit
import PhantomUI
import SwiftUI

/// Explicit action rendered in the profile card action rail.
public struct ProfileCardAction: Identifiable {
    public let id: String
    public let label: String
    public let systemImage: String
    public let role: ButtonRole?
    public let isEnabled: Bool
    public let action: () -> Void

    public init(
        id: String? = nil,
        label: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.id = id ?? label
        self.label = label
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// Card representation of a `VpnProfile` used inside the Settings list.
///
/// Visual elements:
/// - Left "active" glow handled by `GhostCard(active:)` when `isActive == true`.
/// - Top row: profile `name` (left) and colored ping dot + numeric ms (right).
/// - Hairline divider.
/// - Bottom row: `serverAddr` (left) and subscription expiry label (right).
public struct ProfileCard: View {

    /// The profile to render.
    public let profile: VpnProfile
    /// Whether this is the currently-active profile. Triggers the left glow.
    public let isActive: Bool
    /// Latency to the server in milliseconds. `nil` → "--" placeholder; negative
    /// sentinel (`< 0`) → "FAIL" placeholder.
    public let pingMs: Int?
    /// Whether ping is actively in-flight. When `true` the ping slot shows
    /// a muted spinner in place of the numeric value.
    public let isPinging: Bool
    /// Subscription expiry Unix timestamp (seconds). `nil` → no expiry line.
    public let expiresAt: Int64?

    /// Invoked on short tap — typically opens profile details.
    public let onTap: () -> Void
    /// Legacy long-press callback kept for existing call sites.
    public let onLongPress: () -> Void
    /// Explicit profile actions. Prefer these over hidden long-press gestures.
    private let actions: [ProfileCardAction]

    @Environment(\.gsColors) private var C

    /// Creates a new profile card.
    public init(
        profile: VpnProfile,
        isActive: Bool,
        pingMs: Int?,
        isPinging: Bool = false,
        expiresAt: Int64? = nil,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void,
        actions: [ProfileCardAction] = []
    ) {
        self.profile = profile
        self.isActive = isActive
        self.pingMs = pingMs
        self.isPinging = isPinging
        self.expiresAt = expiresAt
        self.onTap = onTap
        self.onLongPress = onLongPress
        self.actions = actions
    }

    public var body: some View {
        GhostCard(active: isActive) {
            VStack(alignment: .leading, spacing: 8) {
                profileSummary
                if !actions.isEmpty {
                    HairlineDivider()
                    actionRow
                }
            }
        }
    }

    // MARK: - Rows

    private var profileSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            HairlineDivider()
            bottomRow
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(profileAccessibilityLabel)
        .accessibilityValue(isActive ? "Активный" : "Не активный")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Открыть профиль") { onTap() }
    }

    private var topRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(profile.name)
                .gsFont(.profileName)
                .foregroundColor(C.bone)
                .lineLimit(1)

            Spacer(minLength: 8)

            pingView
        }
    }

    private var bottomRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(profile.serverAddr.isEmpty ? "—" : profile.serverAddr)
                .gsFont(.body)
                .foregroundColor(C.textDim)
                .lineLimit(1)

            Spacer(minLength: 8)

            if let expiry = expiresAt {
                subscriptionView(expiry: expiry)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            ForEach(actions) { action in
                actionButton(action)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 1)
    }

    private func actionButton(_ action: ProfileCardAction) -> some View {
        Button(role: action.role) {
            action.action()
        } label: {
            Image(systemName: action.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(action.role == .destructive ? C.danger : C.textDim)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(C.bgElev2.opacity(action.isEnabled ? 0.78 : 0.35))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(C.hair.opacity(action.isEnabled ? 1 : 0.45), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.55)
        .accessibilityLabel(action.label)
    }

    // MARK: - Ping

    private var pingView: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pingColor)
                .frame(width: 6, height: 6)

            if isPinging {
                ProgressView()
                    .controlSize(.mini)
                    .tint(C.textDim)
            } else if let ms = pingMs {
                if ms < 0 {
                    Text("FAIL").gsFont(.labelMonoSmall).foregroundColor(C.danger)
                } else {
                    Text("\(ms) MS").gsFont(.labelMonoSmall).foregroundColor(pingColor)
                }
            } else {
                Text("-- MS").gsFont(.labelMonoSmall).foregroundColor(C.textFaint)
            }
        }
    }

    private var pingColor: Color {
        guard let ms = pingMs else { return C.textFaint }
        if ms < 0      { return C.danger }       // unreachable sentinel
        if ms < 100    { return C.signal }
        if ms < 300    { return C.warn }
        return C.danger
    }

    private var profileAccessibilityLabel: String {
        let host = profile.serverAddr.isEmpty ? "адрес не указан" : profile.serverAddr
        return "\(profile.name), \(host)"
    }

    // MARK: - Subscription

    private func subscriptionView(expiry: Int64) -> some View {
        let now = Int64(Date().timeIntervalSince1970)
        let secondsLeft = expiry - now
        let expired = secondsLeft <= 0
        let color: Color = expired ? C.danger : (secondsLeft < 3 * 86_400 ? C.warn : C.textDim)

        return Text(expired ? "ИСТЕКЛА" : formatRemaining(secondsLeft))
            .gsFont(.labelMonoSmall)
            .foregroundColor(color)
    }

    private func formatRemaining(_ secs: Int64) -> String {
        let days = secs / 86_400
        if days >= 1 { return "\(days)Д" }
        let hours = max(1, secs / 3_600)
        return "\(hours)Ч"
    }
}

#if DEBUG
struct ProfileCard_Previews: PreviewProvider {
    static let p1 = VpnProfile(
        id: "a",
        name: "NL · Amsterdam",
        serverAddr: "89.110.109.128:8443",
        serverName: "tls.nl2.bikini-bottom.com",
        tunAddr: "10.7.0.2/24"
    )
    static let p2 = VpnProfile(
        id: "b",
        name: "RU · Relay",
        serverAddr: "193.187.95.128:443",
        serverName: "hostkey.bikini-bottom.com",
        tunAddr: "10.7.0.3/24"
    )

    static var previews: some View {
        VStack(spacing: 10) {
            ProfileCard(
                profile: p1, isActive: true,
                pingMs: 42, expiresAt: Int64(Date().timeIntervalSince1970) + 86_400 * 30,
                onTap: {}, onLongPress: {}
            )
            ProfileCard(
                profile: p2, isActive: false,
                pingMs: 247, expiresAt: nil,
                onTap: {}, onLongPress: {}
            )
            ProfileCard(
                profile: p2, isActive: false,
                pingMs: -1, expiresAt: Int64(Date().timeIntervalSince1970) - 10,
                onTap: {}, onLongPress: {}
            )
            ProfileCard(
                profile: p1, isActive: false,
                pingMs: nil, isPinging: true, expiresAt: nil,
                onTap: {}, onLongPress: {}
            )
        }
        .padding()
        .background(Color(hex: 0xFF0A0908))
        .environment(\.gsColors, .dark)
        .previewLayout(.sizeThatFits)
    }
}
#endif
