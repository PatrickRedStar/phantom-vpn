//
//  WelcomeWindow.swift
//  GhostStream (macOS)
//
//  Мастер первого запуска в стиле mockup.html: системный шрифт, заголовок
//  28 pt, одна lime-кнопка главного действия — справа, последней. Каждая граница прав — свой
//  экран с понятным объяснением по русской macOS и живым ожиданием,
//  которое само переходит дальше.
//
//  Шаги (FSM в OnboardingCoordinator):
//    moveToApplications — запущено не из «Программ»
//    paste              — ссылка ghs://
//    installExt         — системное расширение, «Установить»
//    awaitingApproval   — ждём «Разрешить» в Системных настройках
//    reboot             — macOS закончит установку после перезагрузки
//    configureVpn       — saveToPreferences → системный «Разрешить»
//    ready              — «Подключиться»
//

import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

public struct WelcomeWindow: View {

    @Environment(\.gsColors) private var C
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(ProfilesStore.self) private var profiles
    @Environment(PreferencesStore.self) private var prefs
    @Environment(SystemExtensionInstaller.self) private var sysExt
    @EnvironmentObject private var tunnel: VpnTunnelController

    @State private var coordinator: OnboardingCoordinator
    private let preview: Bool

    /// UI-R4-R02: we observe `NSWindow.willCloseNotification` rather
    /// than relying on `.onDisappear`. The observer token is retained
    /// here so it is properly removed when the view is torn down.
    @State private var willCloseObserver: NSObjectProtocol?

    public init() {
        _coordinator = State(initialValue: OnboardingCoordinator())
        preview = false
    }

    #if DEBUG
    /// Снимки DebugDemo: конкретный шаг без resync и без NE.
    init(previewStep: OnboardingCoordinator.Step) {
        _coordinator = State(initialValue: OnboardingCoordinator(previewStep: previewStep))
        preview = true
    }
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                switch coordinator.step {
                case .moveToApplications:
                    MoveToApplicationsStepView()
                case .paste:
                    PasteStepView(coordinator: coordinator)
                case .installExt:
                    InstallExtStepView(coordinator: coordinator)
                case .awaitingApproval:
                    AwaitingApprovalStepView(coordinator: coordinator)
                case .reboot:
                    RebootStepView(onClose: close)
                case .configureVpn:
                    ConfigureVpnStepView(coordinator: coordinator)
                case .ready:
                    ReadyStepView(coordinator: coordinator, onClose: close)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 48)
        .padding(.top, 36)
        .padding(.bottom, 32)
        .frame(width: 720, height: 560)
        .background(C.bg)
        .onAppear {
            guard !preview else { return }
            coordinator.profiles = profiles
            coordinator.sysExt = sysExt
            coordinator.tunnel = tunnel
            coordinator.preferences = prefs
            Task { await coordinator.resync() }
            installWillCloseObserver()
        }
        // UI-R2-N23 / UI-R4-R02: ⌘W или красная кнопка до `.ready` —
        // сбрасываем FSM (иначе мастер залипал на шаге ожидания). Слушаем
        // именно willClose: `.onDisappear` срабатывал и на ⌘H/сворачивание.
        .onDisappear {
            if let token = willCloseObserver {
                NotificationCenter.default.removeObserver(token)
                willCloseObserver = nil
            }
        }
    }

    private func close() {
        dismissWindow(id: "welcome")
        // Fallback для восстановленных окон, которых SwiftUI не отслеживает.
        if let window = Self.window {
            window.close()
        } else {
            dismiss()
        }
    }

    /// SwiftUI даёт окну identifier вида «welcome-AppWindow-1».
    private static var window: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("welcome") == true }
    }

    private func installWillCloseObserver() {
        guard willCloseObserver == nil else { return }
        let capturedCoordinator = coordinator
        Task { @MainActor in
            // Один тик: `.onAppear` бывает раньше, чем AppKit отдаст NSWindow.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard willCloseObserver == nil, let window = Self.window else { return }
            willCloseObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    capturedCoordinator.dismissedBeforeReady()
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: GsSpace.m) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            Text(verbatim: "GhostStream")
                .gsType(.headline)
                .foregroundStyle(C.bone)
            Spacer()
            if let number = coordinator.step.number {
                Text(String(format: L("welcome.step"), "\(number)", "4"))
                    .gsType(.caption)
                    .foregroundStyle(C.textDim)
            }
        }
        .padding(.bottom, GsSpace.xxl + GsSpace.s)
    }
}

// MARK: - Общие куски шагов

/// Заголовок и пояснение шага.
private struct StepIntro: View {
    let title: String
    let text: String

    @Environment(\.gsColors) private var C

    var body: some View {
        VStack(alignment: .leading, spacing: GsSpace.m) {
            Text(title)
                .gsType(.title)
                .foregroundStyle(C.bone)
            Text(text)
                .gsType(.body)
                .foregroundStyle(C.textDim)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
        }
        .padding(.bottom, GsSpace.xl)
    }
}

/// Главная кнопка мастера (lime) или вторичная (стекло).
private struct WizardButton: View {
    let title: String
    var prominent = true
    let action: () -> Void

    @Environment(\.gsColors) private var C
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let button = Button(action: action) {
            Text(title)
                .gsType(.body)
                .fontWeight(.semibold)
                .foregroundStyle(!isEnabled ? C.textFaint : prominent ? C.bg : C.bone)
                .padding(.horizontal, GsSpace.s)
        }
        .controlSize(.large)
        if prominent {
            button.gsProminentButton(tint: C.signal)
        } else {
            button.gsGlassButton()
        }
    }
}

/// Строка ошибки под действием.
private struct WizardError: View {
    let text: String?

    @Environment(\.gsColors) private var C

    var body: some View {
        if let text {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .gsType(.caption)
                .foregroundStyle(C.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, GsSpace.m)
        }
    }
}

/// Карточка «ждём…»: пульсирующая точка и текст.
private struct WaitingCard: View {
    let text: String
    var done = false

    @Environment(\.gsColors) private var C

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous)
        HStack(spacing: GsSpace.m) {
            StateDot(state: done ? .connected : .connecting, size: 10)
            Text(text)
                .gsType(.body)
                .foregroundStyle(C.bone)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GsSpace.l)
        .padding(.vertical, 14)
        .background(C.bgElev, in: shape)
        .overlay(shape.stroke(C.hair, lineWidth: 1))
    }
}

// MARK: - Перенесите в «Программы»

private struct MoveToApplicationsStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(title: L("welcome.move.title"), text: L("welcome.move.body"))
            Spacer()
            HStack(spacing: GsSpace.m) {
                WizardButton(title: L("menu.quit"), prominent: false) {
                    NSApp.terminate(nil)
                }
                WizardButton(title: L("welcome.move.open")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Шаг 1: ссылка

private struct PasteStepView: View {

    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles
    @Bindable var coordinator: OnboardingCoordinator

    @State private var ghsText: String = ""
    @State private var clipboardCandidate: String?
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(title: L("welcome.paste.title"), text: L("welcome.paste.body"))
            if let candidate = clipboardCandidate {
                clipboardBanner(candidate)
                    .padding(.bottom, GsSpace.m)
            }
            PasteGhsField(text: $ghsText)
                .frame(height: clipboardCandidate == nil ? 140 : 96)
            WizardError(text: importError)
            Spacer()
            WizardButton(title: L("welcome.paste.add")) { importGhs() }
                .disabled(ghsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .onAppear { detectClipboard() }
    }

    private func clipboardBanner(_ candidate: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous)
        return HStack(spacing: GsSpace.m) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 16))
                .foregroundStyle(C.signal)
            Text(String(format: L("welcome.paste.clipboard"), host(of: candidate)))
                .gsType(.body)
                .foregroundStyle(C.bone)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: GsSpace.m)
            WizardButton(title: L("welcome.paste.use"), prominent: false) {
                ghsText = candidate
                clipboardCandidate = nil
            }
            .controlSize(.regular)
        }
        .padding(.leading, 14)
        .padding([.vertical, .trailing], GsSpace.s)
        .background {
            shape.fill(C.bgElev).overlay(shape.fill(C.signal.opacity(0.09)))
        }
        .overlay(shape.stroke(C.signal.opacity(0.3), lineWidth: 1))
    }

    private func detectClipboard() {
        if let str = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           str.hasPrefix("ghs://") {
            clipboardCandidate = str
        }
    }

    private func importGhs() {
        let trimmed = ghsText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try profiles.importFromConnString(trimmed)
            ghsText = ""
            importError = nil
            coordinator.didImportProfile()
        } catch {
            importError = L("welcome.paste.invalid")
        }
    }

    /// Хост сервера из ссылки — чтобы было видно, что за профиль в буфере.
    private func host(of link: String) -> String {
        guard let at = link.range(of: "@", options: .backwards)?.upperBound else { return "ghs://" }
        return String(link[at...].prefix { $0 != "?" && $0 != "#" && $0 != "/" })
    }
}

// MARK: - Шаг 2: системное расширение

private struct InstallExtStepView: View {

    @Environment(\.gsColors) private var C
    @Bindable var coordinator: OnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(title: L("welcome.install.title"), text: L("welcome.install.body"))
            VStack(alignment: .leading, spacing: GsSpace.m) {
                numbered(1, L("welcome.install.step1"))
                numbered(2, L("welcome.install.step2"))
                numbered(3, L("welcome.install.step3"))
            }
            WizardError(text: coordinator.lastError)
            Spacer()
            WizardButton(title: L("welcome.install.action")) {
                coordinator.kickOffInstall()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func numbered(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GsSpace.m) {
            Text(verbatim: "\(n)")
                .gsType(.caption)
                .fontWeight(.bold)
                .foregroundStyle(C.signal)
                .frame(width: 22, height: 22)
                .background(Circle().fill(C.signal.opacity(0.15)))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text)
                .gsType(.body)
                .foregroundStyle(C.bone)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Шаг 2: ждём «Разрешить»

private struct AwaitingApprovalStepView: View {

    @Environment(SystemExtensionInstaller.self) private var sysExt
    @Bindable var coordinator: OnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(title: L("welcome.approve.title"), text: L("welcome.approve.body"))
            WaitingCard(text: statusText, done: sysExt.state == .activated)
            WizardError(text: coordinator.lastError)
            Spacer()
            HStack(spacing: GsSpace.m) {
                WizardButton(title: L("welcome.approve.retry"), prominent: false) {
                    coordinator.kickOffInstall()
                }
                WizardButton(title: L("welcome.approve.open")) {
                    OnboardingCoordinator.openSystemSettingsLoginItems()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var statusText: String {
        switch sysExt.state {
        case .notInstalled, .requestPending:
            return L("welcome.approve.pending")
        case .awaitingUserApproval:
            return L("welcome.approve.waiting")
        case .activated:
            return L("welcome.approve.done")
        case .failed(let message):
            return message
        }
    }
}

// MARK: - Шаг 2: перезагрузка

private struct RebootStepView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(title: L("welcome.reboot.title"), text: L("welcome.reboot.body"))
            Spacer()
            WizardButton(title: L("general.done"), prominent: false, action: onClose)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Шаг 3: конфигурация VPN

private struct ConfigureVpnStepView: View {

    @Bindable var coordinator: OnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(title: L("welcome.configure.title"), text: L("welcome.configure.body"))
            if coordinator.awaitingVpnApproval {
                WaitingCard(text: L("welcome.configure.waiting"))
            }
            WizardError(text: coordinator.lastError)
            Spacer()
            WizardButton(title: L("welcome.configure.action")) {
                Task { await coordinator.configureVpn() }
            }
            .disabled(coordinator.awaitingVpnApproval)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Шаг 4: готово

private struct ReadyStepView: View {

    @Environment(\.gsColors) private var C
    @Environment(\.openWindow) private var openWindow
    @Environment(ProfilesStore.self) private var profiles
    @Environment(PreferencesStore.self) private var prefs
    @EnvironmentObject private var tunnel: VpnTunnelController
    @Bindable var coordinator: OnboardingCoordinator
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIntro(title: L("welcome.ready.title"), text: L("welcome.ready.body"))
            VStack(alignment: .leading, spacing: GsSpace.m) {
                checkRow(L("welcome.ready.profile"))
                checkRow(L("welcome.ready.extension"))
                checkRow(L("welcome.ready.config"))
            }
            Spacer()
            // Как в диалогах macOS: кнопки справа, главная — последней.
            HStack(spacing: GsSpace.m) {
                WizardButton(title: L("welcome.ready.later"), prominent: false) { finish(connect: false) }
                WizardButton(title: L("welcome.connect_now")) { finish(connect: true) }
                    .disabled(profiles.activeProfile == nil)
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Запуск идёт в своей Task (VpnTunnelController живёт в приложении),
    /// окно закрываем сразу. Дальше — консоль с подсказкой про строку меню,
    /// чтобы пользователь не остался без окна.
    private func finish(connect: Bool) {
        if connect, let profile = profiles.activeProfile {
            Task { try? await tunnel.installAndStart(profile: profile, preferences: prefs) }
        }
        coordinator.finish()
        MenuBarHint.show()
        openWindow(id: "console")
        DockPolicyController.shared.activateForegroundWindow()
        onClose()
    }

    private func checkRow(_ text: String) -> some View {
        HStack(spacing: GsSpace.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(C.signal)
            Text(text)
                .gsType(.body)
                .foregroundStyle(C.bone)
        }
    }
}

// MARK: - Подсказка в консоли после мастера

/// «GhostStream живёт в строке меню» — внизу консоли один раз после мастера.
struct MenuBarHint: View {

    private static let key = "menuBarHintPending"

    static func show() {
        UserDefaults.standard.set(true, forKey: key)
    }

    @AppStorage(MenuBarHint.key) private var pending = false
    @Environment(\.gsColors) private var C

    var body: some View {
        if pending {
            let shape = RoundedRectangle(cornerRadius: GsRadius.group, style: .continuous)
            HStack(spacing: GsSpace.m) {
                Image(systemName: "menubar.arrow.up.rectangle")
                    .font(.system(size: 20))
                    .foregroundStyle(C.signal)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("menubar_hint.title"))
                        .gsType(.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(C.bone)
                    Text(L("menubar_hint.body"))
                        .gsType(.caption)
                        .foregroundStyle(C.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: GsSpace.m)
                Button(L("menubar_hint.ok")) { pending = false }
                    .gsType(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(C.bg)
                    .gsProminentButton(tint: C.signal)
            }
            .padding(.leading, GsSpace.l)
            .padding([.vertical, .trailing], GsSpace.m)
            .frame(maxWidth: 560)
            .background(C.bgElev, in: shape)
            .overlay(shape.stroke(C.signal.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            .padding(.bottom, GsSpace.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
