//
//  ProfileCard.swift
//  GhostStream
//
//  Tall card representing a single VPN profile in the Settings list.
//  Shows name, server address, ping indicator and subscription expiry.
//

import SwiftUI

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

    /// Invoked on short tap — typically "set as active".
    public let onTap: () -> Void
    /// Invoked on long-press — typically opens rename / delete menu.
    public let onLongPress: () -> Void

    @Environment(\.gsColors) private var C

    /// Creates a new profile card.
    public init(
        profile: VpnProfile,
        isActive: Bool,
        pingMs: Int?,
        isPinging: Bool = false,
        expiresAt: Int64? = nil,
        onTap: @escaping () -> Void,
        onLongPress: @escaping () -> Void
    ) {
        self.profile = profile
        self.isActive = isActive
        self.pingMs = pingMs
        self.isPinging = isPinging
        self.expiresAt = expiresAt
        self.onTap = onTap
        self.onLongPress = onLongPress
    }

    public var body: some View {
        GhostCard(active: isActive) {
            VStack(alignment: .leading, spacing: 8) {
                topRow
                HairlineDivider()
                bottomRow
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
    }

    // MARK: - Rows

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
