import SwiftUI
import PhantomKit
import PhantomUI

struct ProfileDetailView: View {
    let profile: VpnProfile
    let isActive: Bool
    let pingMs: Int?
    let onSetActive: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onOpenAdmin: () -> Void

    @Environment(\.gsColors) private var C

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                actionSection
                identitySection
                subscriptionSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(C.bg.ignoresSafeArea())
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.large)
    }

    private var headerCard: some View {
        GhostCard(active: isActive) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(profile.serverAddr.isEmpty ? L("profile.no.server.address") : profile.serverAddr)
                        .font(.subheadline)
                        .foregroundStyle(C.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 12)
                    NativeStatusPill(
                        text: profile.cachedIsAdmin == true ? L("profile.role.admin") : L("profile.role.user"),
                        tone: profile.cachedIsAdmin == true ? .success : .neutral
                    )
                }

                HStack(spacing: 8) {
                    Text(isActive ? L("profile.active") : L("profile.saved"))
                        .font(.caption)
                        .foregroundStyle(C.textFaint)
                    if let pingText {
                        Text(pingText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(C.textFaint)
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        let actions = ProfilePresentation.actions(for: profile, isActive: isActive)
        return NativeSectionCard {
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                row(for: action)
                if index < actions.count - 1 {
                    HairlineDivider()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for action: ProfileActionKind) -> some View {
        switch action {
        case .serverControl:
            NativeRow(
                title: L("native.profile.server.control"),
                subtitle: L("native.profile.server.control.subtitle"),
                action: onOpenAdmin
            )
        case .createClientLink:
            NativeRow(
                title: L("native.profile.create.client.link"),
                subtitle: L("profile.create.client.subtitle"),
                action: onOpenAdmin
            )
        case .identity:
            NativeRow(title: L("native.profile.identity"), subtitle: displayValue(profile.tunAddr), action: nil) {
                EmptyView()
            }
        case .subscription:
            NativeRow(title: L("native.profile.subscription"), subtitle: subscriptionText, action: nil) {
                EmptyView()
            }
        case .setActive:
            NativeRow(
                title: L("native.profile.set.active"),
                subtitle: L("profile.set.active.subtitle"),
                action: onSetActive
            )
        case .edit:
            NativeRow(
                title: L("native.profile.edit.endpoint"),
                subtitle: L("profile.edit.subtitle"),
                action: onEdit
            )
        case .share:
            shareRow
        case .delete:
            NativeRow(
                title: L("profile.delete"),
                subtitle: L("profile.delete.subtitle"),
                role: .destructive,
                action: onDelete
            )
        }
    }

    @ViewBuilder
    private var shareRow: some View {
        if let connString = profile.connString, !connString.isEmpty {
            ShareLink(item: connString) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("native.profile.share.device"))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(C.bone)
                        Text(L("profile.share.subtitle"))
                            .font(.footnote)
                            .foregroundStyle(C.textDim)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "square.and.arrow.up")
                        .foregroundStyle(C.textFaint)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        } else {
            NativeRow(title: L("native.profile.share.device"), subtitle: L("profile.share.unavailable"), action: nil) {
                EmptyView()
            }
        }
    }

    private var identitySection: some View {
        NativeSectionCard {
            NativeRow(title: L("profile.assigned.address"), subtitle: displayValue(profile.tunAddr), action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: L("profile.certificate"), subtitle: certificateText, action: nil) {
                EmptyView()
            }
            HairlineDivider()
            NativeRow(title: L("profile.admin.fingerprint"), subtitle: displayValue(profile.cachedAdminServerCertFp), action: nil) {
                EmptyView()
            }
        }
    }

    private var subscriptionSection: some View {
        NativeSectionCard {
            NativeRow(title: L("native.profile.subscription"), subtitle: subscriptionText, action: nil) {
                EmptyView()
            }
        }
    }

    private var pingText: String? {
        guard let pingMs else { return nil }
        return pingMs < 0 ? L("profile.ping.failed") : "\(pingMs) ms"
    }

    private var certificateText: String {
        profile.certPem == nil ? L("profile.certificate.keychain") : L("profile.certificate.loaded")
    }

    private var subscriptionText: String {
        guard let expiresAt = profile.cachedExpiresAt else { return L("profile.subscription.no.expiry") }
        let remaining = expiresAt - Int64(Date().timeIntervalSince1970)
        if remaining <= 0 { return L("profile.subscription.expired") }
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        return String(format: L("profile.subscription.remaining.format"), days, hours)
    }

    private func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return L("profile.value.unavailable") }
        return value
    }
}

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}
