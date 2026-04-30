//
//  WelcomeWindow.swift
//  GhostStream (macOS)
//
//  Multi-step onboarding wizard. Replaces the silent "permission denied"
//  failure with a guided flow modelled after best-in-class macOS VPN
//  clients (Mullvad, Tailscale, Wireguard.app, Proton): each permission
//  boundary gets its own screen with a human-readable explanation, a
//  primary action button, a System Settings deeplink fallback, and live
//  polling that auto-advances when state changes.
//
//  Steps (FSM in OnboardingCoordinator):
//    1. paste            — paste ghs:// (existing flow, lightly adapted)
//    2. installExt       — explain system extension, "Установить" CTA
//    3. awaitingApproval — live banner + "Открыть System Settings" deeplink
//    4. configureVpn     — saveToPreferences → user clicks Allow VPN
//    5. ready            — "Готово, можно подключаться"
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

    @State private var coordinator = OnboardingCoordinator()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandBlock
            stepsRail
            HairlineDivider().padding(.bottom, 28)
            Group {
                switch coordinator.step {
                case .paste:
                    PasteStepView(coordinator: coordinator)
                case .installExt:
                    InstallExtStepView(coordinator: coordinator)
                case .awaitingApproval:
                    AwaitingApprovalStepView(coordinator: coordinator)
                case .configureVpn:
                    ConfigureVpnStepView(coordinator: coordinator)
                case .ready:
                    ReadyStepView(coordinator: coordinator) {
                        dismissWindow(id: "welcome")
                        // Keep direct NSWindow fallback for older/restored windows that are not tracked by SwiftUI.
                        if let win = NSApp.windows.first(where: { $0.identifier?.rawValue == "welcome" || $0.title == "Welcome" }) {
                            win.close()
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .padding(.top, 40)
        .padding(.bottom, 36)
        .frame(width: 720, height: 560)
        .background(C.bg)
        .onAppear {
            coordinator.profiles = profiles
            coordinator.sysExt = sysExt
            coordinator.tunnel = tunnel
            coordinator.preferences = prefs
            Task { await coordinator.resync() }
        }
    }

    // MARK: - Brand block

    @ViewBuilder
    private var brandBlock: some View {
        HStack(spacing: 14) {
            ScopeRingGlyph(size: 30, signal: C.signal, dim: C.signalDim)
            Text("Ghoststream")
                .font(.custom("SpaceGrotesk-Bold", size: 22))
                .tracking(-0.02 * 22)
                .foregroundStyle(C.bone)
            Spacer()
            Text("v0.23.0 · macOS · setup")
                .font(.custom("DepartureMono-Regular", size: 10.5))
                .tracking(0.18 * 10.5)
                .foregroundStyle(C.textFaint)
        }
        .padding(.bottom, 24)
    }

    // MARK: - Steps rail (1—2—3—4)

    @ViewBuilder
    private var stepsRail: some View {
        let labels: [(OnboardingCoordinator.Step, String)] = [
            (.paste,            "01 · ПОДКЛЮЧИСЬ"),
            (.installExt,       "02 · УСТАНОВИ"),
            (.awaitingApproval, "03 · РАЗРЕШИ"),
            (.configureVpn,     "04 · ГОТОВО"),
        ]
        HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.0) { idx, item in
                let (step, label) = item
                let active = coordinator.step == step
                let done   = coordinator.step.rawValue > step.rawValue
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .stroke(done || active ? C.signal : C.hairBold, lineWidth: 1)
                            .frame(width: 18, height: 18)
                        if done {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(C.signal)
                        } else {
                            Text("\(idx + 1)")
                                .font(.custom("DepartureMono-Regular", size: 10))
                                .foregroundStyle(active ? C.signal : C.textFaint)
                        }
                    }
                    Text(label)
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .tracking(0.18 * 9.5)
                        .foregroundStyle(active ? C.bone : (done ? C.textDim : C.textFaint))
                }
                if idx < labels.count - 1 {
                    Rectangle()
                        .fill(done ? C.signal : C.hair)
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                }
            }
        }
        .padding(.bottom, 22)
    }
}

// MARK: - Step 1: Paste

private struct PasteStepView: View {

    @Environment(\.gsColors) private var C
    @Environment(ProfilesStore.self) private var profiles
    @Bindable var coordinator: OnboardingCoordinator

    @State private var ghsText: String = ""
    @State private var clipboardCandidate: String?
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            subtitle
            if let candidate = clipboardCandidate {
                clipboardBanner(candidate)
                    .padding(.bottom, 14)
            }
            PasteGhsField(text: $ghsText)
                .frame(minHeight: 120)
            if let err = importError {
                Text(err)
                    .font(.custom("JetBrainsMono-Regular", size: 11))
                    .foregroundStyle(C.danger)
                    .padding(.top, 6)
            }
            actionRow
        }
        .onAppear { detectClipboard() }
    }

    @ViewBuilder
    private var hero: some View {
        HStack(spacing: 0) {
            Text("Подключись")
                .font(.custom("InstrumentSerif-Italic", size: 36))
                .foregroundStyle(C.signal)
            Text(".")
                .font(.custom("SpaceGrotesk-Bold", size: 36))
                .foregroundStyle(C.bone)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var subtitle: some View {
        (Text("Вставь ")
            .font(.custom("JetBrainsMono-Regular", size: 13.5))
            .foregroundColor(C.textDim)
        + Text("ghs://")
            .font(.custom("JetBrainsMono-Regular", size: 13.5))
            .foregroundColor(C.signal)
        + Text(" connection string которую тебе выдали. В ней зашиты сертификат, ключ и адрес — это всё что нужно для подключения.")
            .font(.custom("JetBrainsMono-Regular", size: 13.5))
            .foregroundColor(C.textDim))
            .lineSpacing(5)
            .padding(.bottom, 18)
    }

    @ViewBuilder
    private func clipboardBanner(_ candidate: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(C.signal)
                .frame(width: 24, height: 24)
                .overlay(Rectangle().stroke(C.signal, lineWidth: 1))
            (Text("В буфере найдено ")
                .foregroundColor(C.bone)
            + Text("ghs://")
                .foregroundColor(C.signal)
            + Text(" · \(parsePreview(candidate))")
                .foregroundColor(C.bone))
                .font(.custom("JetBrainsMono-Regular", size: 12.5))
            Spacer()
            Button {
                ghsText = candidate
                clipboardCandidate = nil
            } label: {
                HStack(spacing: 6) {
                    Text("PASTE")
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .tracking(0.18 * 10.5)
                    Text("· ⌘V")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .opacity(0.6)
                }
                .foregroundStyle(C.signal)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Rectangle().stroke(C.signal, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            LinearGradient(colors: [C.signal.opacity(0.04), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            Rectangle().strokeBorder(
                C.signalDim,
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        )
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 14) {
            Button { importGhs() } label: {
                HStack(spacing: 8) {
                    Text("ИМПОРТИРОВАТЬ")
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.20 * 11)
                    Text("⌘⏎")
                        .font(.custom("DepartureMono-Regular", size: 9.5))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(Rectangle().stroke(C.signalDim, lineWidth: 1))
                }
                .foregroundStyle(ghsText.isEmpty ? C.textFaint : C.signal)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .overlay(
                    Rectangle().stroke(ghsText.isEmpty ? C.hairBold : C.signal, lineWidth: 1)
                )
                .background(
                    LinearGradient(
                        colors: [C.signal.opacity(0.06), C.signal.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                    .opacity(ghsText.isEmpty ? 0 : 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(ghsText.isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            Spacer()
        }
        .padding(.top, 22)
    }

    private func detectClipboard() {
        let pb = NSPasteboard.general
        if let str = pb.string(forType: .string), str.hasPrefix("ghs://") {
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
            importError = "Неверная ghs:// строка"
        }
    }

    private func parsePreview(_ s: String) -> String {
        if let atIdx = s.range(of: "@", options: .backwards)?.upperBound {
            let tail = s[atIdx...]
            return String(tail.prefix(while: { $0 != "?" && $0 != "#" }))
        }
        return "ghs config"
    }
}

// MARK: - Step 2: Install system extension

private struct InstallExtStepView: View {

    @Environment(\.gsColors) private var C
    @Bindable var coordinator: OnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Установи")
                    .font(.custom("InstrumentSerif-Italic", size: 36))
                    .foregroundStyle(C.signal)
                Text(" туннель.")
                    .font(.custom("SpaceGrotesk-Bold", size: 36))
                    .foregroundStyle(C.bone)
            }
            .padding(.bottom, 14)

            (Text("GhostStream использует ")
                .foregroundColor(C.textDim)
            + Text("системное расширение")
                .foregroundColor(C.bone)
            + Text(" — это часть macOS, которая запускается отдельно от приложения и обрабатывает сетевые пакеты. Без него VPN-туннель работать не сможет — это ограничение операционной системы, а не нашей прихоти.")
                .foregroundColor(C.textDim))
                .font(.custom("JetBrainsMono-Regular", size: 13.5))
                .lineSpacing(5)
                .padding(.bottom, 18)

            // bullet list of what will happen
            VStack(alignment: .leading, spacing: 10) {
                bullet("macOS попросит подтвердить установку.")
                bullet("Откроется System Settings → Login Items & Extensions.")
                bullet("Раскрой Extensions → Network Extensions.")
                bullet("Найди GhostStream и нажми Allow.")
                bullet("Этот шаг делается один раз — потом всё автоматически.")
            }
            .padding(.bottom, 26)

            HStack(spacing: 14) {
                Button {
                    coordinator.kickOffInstall()
                } label: {
                    Text("УСТАНОВИТЬ РАСШИРЕНИЕ")
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.20 * 11)
                        .foregroundStyle(C.signal)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .overlay(Rectangle().stroke(C.signal, lineWidth: 1))
                        .background(
                            LinearGradient(
                                colors: [C.signal.opacity(0.06), C.signal.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
                .buttonStyle(.plain)

                if let err = coordinator.lastError {
                    Text(err)
                        .font(.custom("JetBrainsMono-Regular", size: 11.5))
                        .foregroundStyle(C.danger)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: 360, alignment: .leading)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("·")
                .font(.custom("JetBrainsMono-Regular", size: 13.5))
                .foregroundStyle(C.signal)
            Text(text)
                .font(.custom("JetBrainsMono-Regular", size: 13))
                .foregroundStyle(C.textDim)
        }
    }
}

// MARK: - Step 3: Awaiting approval

private struct AwaitingApprovalStepView: View {

    @Environment(\.gsColors) private var C
    @Environment(SystemExtensionInstaller.self) private var sysExt
    @Bindable var coordinator: OnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Жду")
                    .font(.custom("InstrumentSerif-Italic", size: 36))
                    .foregroundStyle(C.warn)
                Text(" разрешения.")
                    .font(.custom("SpaceGrotesk-Bold", size: 36))
                    .foregroundStyle(C.bone)
            }
            .padding(.bottom, 14)

            (Text("macOS должен подтвердить установку расширения. Открой ")
                .foregroundColor(C.textDim)
            + Text("System Settings → General → Login Items & Extensions → Network Extensions")
                .foregroundColor(C.bone)
            + Text(" и нажми ")
                .foregroundColor(C.textDim)
            + Text("Allow")
                .foregroundColor(C.signal)
            + Text(" рядом с GhostStream. Как только разрешишь — этот шаг закроется сам.")
                .foregroundColor(C.textDim))
                .font(.custom("JetBrainsMono-Regular", size: 13.5))
                .lineSpacing(5)
                .padding(.bottom, 22)

            // Live status panel
            HStack(spacing: 14) {
                PulseDot(color: C.warn, size: 10, pulse: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("ОЖИДАНИЕ ДЕЙСТВИЯ ПОЛЬЗОВАТЕЛЯ")
                        .font(.custom("DepartureMono-Regular", size: 10))
                        .tracking(0.20 * 10)
                        .foregroundStyle(C.warn)
                    Text(statusText)
                        .font(.custom("JetBrainsMono-Regular", size: 12.5))
                        .foregroundStyle(C.bone)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(C.bgElev2)
            .overlay(Rectangle().stroke(C.warn.opacity(0.4), lineWidth: 1))
            .padding(.bottom, 22)

            HStack(spacing: 14) {
                Button {
                    OnboardingCoordinator.openSystemSettingsLoginItems()
                } label: {
                    Text("ОТКРЫТЬ NETWORK EXTENSIONS")
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.20 * 11)
                        .foregroundStyle(C.signal)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .overlay(Rectangle().stroke(C.signal, lineWidth: 1))
                        .background(
                            LinearGradient(
                                colors: [C.signal.opacity(0.06), C.signal.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                }
                .buttonStyle(.plain)

                Button {
                    coordinator.kickOffInstall()
                } label: {
                    Text("ОТПРАВИТЬ ЗАПРОС ЗАНОВО")
                        .font(.custom("DepartureMono-Regular", size: 10.5))
                        .tracking(0.18 * 10.5)
                        .foregroundStyle(C.textDim)
                }
                .buttonStyle(.plain)

                Spacer()

                if let err = coordinator.lastError {
                    Text(err)
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundStyle(C.danger)
                        .lineLimit(2)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
            }
        }
    }

    private var statusText: String {
        switch sysExt.state {
        case .requestPending:
            return "Запрос отправлен в систему…"
        case .awaitingUserApproval:
            return sysExt.lastMessage ?? "Жду пока ты нажмёшь Allow в System Settings."
        case .activated:
            return "Получено! Перехожу к следующему шагу…"
        case .failed(let m):
            return "Не удалось: \(m)"
        case .notInstalled:
            return "Расширение не установлено."
        }
    }
}

// MARK: - Step 4: Configure VPN (NEManager)

private struct ConfigureVpnStepView: View {

    @Environment(\.gsColors) private var C
    @Bindable var coordinator: OnboardingCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Сохрани")
                    .font(.custom("InstrumentSerif-Italic", size: 36))
                    .foregroundStyle(C.signal)
                Text(" конфигурацию.")
                    .font(.custom("SpaceGrotesk-Bold", size: 36))
                    .foregroundStyle(C.bone)
            }
            .padding(.bottom, 14)

            (Text("Последний шаг — macOS попросит разрешить добавление VPN-конфигурации. Это стандартный системный диалог: появится окно с кнопкой ")
                .foregroundColor(C.textDim)
            + Text("Allow")
                .foregroundColor(C.signal)
            + Text(", разреши его. После этого ты сможешь подключаться одной кнопкой из меню или dashboard'а.")
                .foregroundColor(C.textDim))
                .font(.custom("JetBrainsMono-Regular", size: 13.5))
                .lineSpacing(5)
                .padding(.bottom, 22)

            if coordinator.awaitingVpnApproval {
                HStack(spacing: 14) {
                    PulseDot(color: C.warn, size: 10, pulse: true)
                    Text("Жду подтверждения VPN-конфигурации…")
                        .font(.custom("JetBrainsMono-Regular", size: 12.5))
                        .foregroundStyle(C.bone)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(C.bgElev2)
                .overlay(Rectangle().stroke(C.warn.opacity(0.4), lineWidth: 1))
                .padding(.bottom, 22)
            }

            HStack(spacing: 14) {
                Button {
                    Task { await coordinator.configureVpn() }
                } label: {
                    Text(coordinator.awaitingVpnApproval ? "ЖДУ…" : "СОХРАНИТЬ И РАЗРЕШИТЬ")
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.20 * 11)
                        .foregroundStyle(coordinator.awaitingVpnApproval ? C.textFaint : C.signal)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .overlay(Rectangle().stroke(coordinator.awaitingVpnApproval ? C.hairBold : C.signal, lineWidth: 1))
                        .background(
                            LinearGradient(
                                colors: [C.signal.opacity(0.06), C.signal.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                            .opacity(coordinator.awaitingVpnApproval ? 0 : 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(coordinator.awaitingVpnApproval)

                Spacer()

                if let err = coordinator.lastError {
                    Text(err)
                        .font(.custom("JetBrainsMono-Regular", size: 11))
                        .foregroundStyle(C.danger)
                        .lineLimit(3)
                        .frame(maxWidth: 280, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Step 5: Ready

private struct ReadyStepView: View {

    @Environment(\.gsColors) private var C
    @Bindable var coordinator: OnboardingCoordinator
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("Готово")
                    .font(.custom("InstrumentSerif-Italic", size: 44))
                    .foregroundStyle(C.signal)
                Text(".")
                    .font(.custom("SpaceGrotesk-Bold", size: 44))
                    .foregroundStyle(C.bone)
            }
            .padding(.bottom, 14)

            Text("Все разрешения выданы. Туннель готов к подключению.")
                .font(.custom("JetBrainsMono-Regular", size: 13.5))
                .foregroundColor(C.textDim)
                .lineSpacing(5)
                .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 12) {
                checkRow("Профиль импортирован")
                checkRow("Системное расширение установлено")
                checkRow("VPN-конфигурация сохранена")
            }
            .padding(.bottom, 26)

            HStack(spacing: 14) {
                Button {
                    coordinator.finish()
                    onClose()
                } label: {
                    Text("ЗАВЕРШИТЬ")
                        .font(.custom("DepartureMono-Regular", size: 11))
                        .tracking(0.20 * 11)
                        .foregroundStyle(C.bg)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 14)
                        .background(C.signal)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("⌘W чтобы закрыть")
                    .font(.custom("DepartureMono-Regular", size: 10))
                    .tracking(0.18 * 10)
                    .foregroundStyle(C.textFaint)
            }
        }
    }

    @ViewBuilder
    private func checkRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(C.signal)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(C.signal, lineWidth: 1))
            Text(text)
                .font(.custom("JetBrainsMono-Regular", size: 13))
                .foregroundStyle(C.bone)
        }
    }
}
