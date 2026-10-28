//
//  GsButtons.swift
//  GhostStream (macOS)
//
//  Кнопки редизайна (mockup.html, `.gl`): стекло только на контролах.
//  macOS 26 — Liquid Glass, раньше — prominent-капсула / материал.
//

import PhantomKit
import PhantomUI
import SwiftUI
import os.log

extension View {
    /// Главное действие (`.gl.pro`): тонированная glass-капсула.
    /// Цвет текста задаёт вызывающий — на лайме нужен тёмный (`C.bg`).
    @ViewBuilder
    func gsProminentButton(tint: Color) -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(tint)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(tint)
        }
    }

    /// Вторичное действие (`.gl`): стеклянная капсула, до macOS 26 — материал.
    @ViewBuilder
    func gsGlassButton() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(MaterialCapsuleButtonStyle())
        }
    }
}

private struct MaterialCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, GsSpace.m)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// «Подключить» / «Отключить» — главная кнопка тулбара (макет `#mainBtn`).
struct ConnectButton: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow
    @Environment(VpnStateManager.self) private var stateMgr
    @Environment(ProfilesStore.self) private var profiles
    @Environment(DockPolicyController.self) private var dock

    var body: some View {
        let state = stateMgr.statusFrame.state
        let (title, prominent) = Self.label(for: state)
        let button = Button {
            Task {
                await ConnectAction.toggle {
                    openWindow(id: "welcome")
                    dock.activateForegroundWindow()
                }
            }
        } label: {
            Label(title, systemImage: "power")
                .labelStyle(.titleAndIcon)
                .gsType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(prominent ? C.bg : C.bone)
                .padding(.horizontal, GsSpace.xs)
        }
        .controlSize(.large)
        .keyboardShortcut("k", modifiers: .command)
        .disabled(profiles.activeProfile == nil
                  || (state == .disconnected && LegacyMigration.state.isMigrating))

        if prominent {
            button.gsProminentButton(tint: C.signal)
        } else {
            button.gsGlassButton()
        }
    }

    /// Подпись и «главность» по макету: отключить живой туннель — lime,
    /// отменить/переподключение/повтор — простое стекло.
    static func label(for state: ConnState) -> (String, Bool) {
        switch state {
        case .disconnected: return (L("action.connect"), true)
        case .connected:    return (L("action.disconnect"), true)
        case .connecting:   return (L("action.cancel"), false)
        case .reconnecting: return (L("action.disconnect"), false)
        case .error:        return (L("action.retry"), false)
        }
    }
}

/// Одна точка «подключить/отключить» для тулбара, дашборда и попапа
/// (раньше — две одинаковые копии в DashboardView и MenuBarPopover).
@MainActor
enum ConnectAction {

    private static let log = Logger(subsystem: "com.ghoststream.client", category: "ConnectAction")

    /// `openWelcome` — открыть мастер, если нет профиля или system extension.
    static func toggle(openWelcome: () -> Void) async {
        #if DEBUG
        if DebugDemo.isActive { return }
        #endif
        let tunnel = VpnTunnelController.shared
        let state = VpnStateManager.shared.statusFrame.state
        // UI-R2-N20: connected → отключить, connecting/reconnecting → отменить.
        // Оба через stop(): зависшее TLS-рукопожатие (до 75 с на ТСПУ)
        // можно оборвать.
        if state == .connected || state == .connecting || state == .reconnecting {
            log.info("toggle → stop (state=\(String(describing: state), privacy: .public))")
            tunnel.stop()
            return
        }
        // MIG-R4-N01: пока фаза B миграции не перенесла cert/key из старого
        // Keychain, коннект молча упадёт на mTLS.
        if LegacyMigration.state.isMigrating {
            log.info("toggle → migration phase B still in flight, refusing CONNECT")
            tunnel.lastError = L("connect.err.migrating")
            return
        }
        if let preflightError = preflightError() {
            log.info("toggle → prerequisites missing, opening Welcome wizard")
            tunnel.lastError = preflightError
            openWelcome()
            return
        }
        guard let profile = ProfilesStore.shared.activeProfile else { return }
        log.info("toggle → installAndStart profile=\(profile.id, privacy: .public)")
        do {
            try await tunnel.installAndStart(profile: profile, preferences: PreferencesStore.shared)
            tunnel.lastError = nil
        } catch {
            log.error("installAndStart failed: \(error.localizedDescription, privacy: .public)")
            tunnel.lastError = ConnectErrorHumanizer.humanize(error.localizedDescription)
        }
    }

    private static func preflightError() -> String? {
        if ProfilesStore.shared.activeProfile == nil {
            return L("connect.err.no_profile")
        }
        switch SystemExtensionInstaller.shared.state {
        case .activated:
            return nil
        case .failed:
            return L("connect.err.sysext_failed")
        case .awaitingUserApproval:
            return L("connect.err.sysext_approval")
        case .requestPending:
            return L("connect.err.sysext_pending")
        case .notInstalled:
            return L("connect.err.sysext_missing")
        }
    }
}
