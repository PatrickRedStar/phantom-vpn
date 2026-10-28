//
//  DebugDemo.swift
//  GhostStream (macOS)
//
//  Хук для скриншотов, только DEBUG (по образцу iOS DebugDemo):
//
//    -gsDemo idle|connecting|connected|reconnecting|error|empty
//    -gsSnapshot <name>    PNG окна на каждый пункт сайдбара (main, servers,
//                          logs, admin, settings) + popover.png, мастер
//                          (welcome*.png) и about.png, затем выход.
//                          Приложение в песочнице, поэтому папка всегда в
//                          tmp контейнера: ~/Library/Containers/
//                          com.ghoststream.client/Data/tmp/<name> (от пути
//                          берётся последний компонент; пути — в stdout)
//    -gsTheme light|dark   иначе системная тема
//
//  Всё живёт в памяти: профили подставлены через volatile argument domain
//  UserDefaults (поверх App Group, на диск не пишется), StatusFrame — в
//  VpnStateManager, туннель/NETunnelProviderManager/system extension не
//  трогаются. Ввод мышью и клавиатурой игнорируется, чтобы клик по
//  тумблеру не записал демо-данные в настоящие настройки; ⌘Q — выход.
//  Снимки своих окон — разрешение на запись экрана не нужно (см. capture).
//

#if DEBUG
import AppKit
import PhantomKit
import PhantomUI
import SwiftUI

enum DebugDemo {

    static let mode = UserDefaults.standard.string(forKey: "gsDemo")
    static var isActive: Bool { mode != nil }

    private static let snapshotDir = UserDefaults.standard.string(forKey: "gsSnapshot")
    private static let theme = UserDefaults.standard.string(forKey: "gsTheme")

    /// До создания сторов: подставить профили и тему поверх App Group.
    static func prepare() {
        guard let mode else { return }
        let profiles = mode == "empty" ? [] : demoProfiles
        var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        args["profiles.json"] = try? JSONEncoder().encode(profiles)
        args["active_id"] = profiles.first?.id ?? ""
        args["theme"] = theme ?? ThemeOverride.system.rawValue
        // Миграция v0.23 видит «уже сделано» и ничего не трогает.
        args["io.ghoststream.migration.v23_to_v24.completed"] = true
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
    }

    /// Баннер обновления в демо: версия на патч новее текущей.
    static var fakeRelease: UpdateChecker.Release? {
        guard isActive else { return nil }
        var parts = UpdateChecker.currentVersion.split(separator: ".").map { Int($0) ?? 0 }
        parts[parts.count - 1] += 1
        return .init(
            version: parts.map(String.init).joined(separator: "."),
            url: URL(string: "https://github.com/PatrickRedStar/phantom-vpn/releases/latest")!
        )
    }

    // MARK: - Data

    private static let demoProfiles: [VpnProfile] = {
        // «Доступ до 12.12 · осталось 45 дн.», как в макете.
        let expires = Int64(Date().timeIntervalSince1970) + 45 * 86_400 - 3_600
        return [
            VpnProfile(id: "demo-relay", name: "Нидерланды · relay",
                       serverAddr: "89.110.109.128:8443", serverName: "tls.nl2.bikini-bottom.com",
                       tunAddr: "10.7.0.12/24", cachedExpiresAt: expires, cachedEnabled: true,
                       cachedIsAdmin: true, relayEnabled: true, relayAddr: "158.160.135.140:443"),
            VpnProfile(id: "demo-direct", name: "Нидерланды · напрямую",
                       serverAddr: "89.110.109.128:8443", serverName: "tls.nl2.bikini-bottom.com",
                       tunAddr: "10.7.0.13/24", cachedExpiresAt: expires, cachedEnabled: true),
            VpnProfile(id: "demo-reserve", name: "Резервный · relay-2",
                       serverAddr: "89.169.175.55:443", serverName: "relay.bikini-bottom.com",
                       tunAddr: "10.7.0.14/24", cachedEnabled: false),
        ]
    }()

    /// StatusFrame демо-туннеля на секунду `tick` (VpnStateManager тикает раз в секунду).
    static func frame(tick: Int) -> StatusFrame {
        var f = StatusFrame.disconnected
        switch mode {
        case "connecting":   f.state = .connecting
        case "connected":    f.state = .connected
        case "reconnecting": f.state = .reconnecting
        case "error":        f.state = .error
        default:             return f
        }
        let t = UInt64(tick)
        f.serverAddr = "158.160.135.140:443"
        f.sni = "tls.nl2.bikini-bottom.com"
        f.tunAddr = "10.7.0.12/24"
        f.nStreams = 8
        switch f.state {
        case .connected:
            let wave = (sin(Double(tick) / 3) + 1) / 2
            f.sessionSecs = 5_077 + t                          // 1:24:37
            f.rateRxBps = 40_000_000 + 16_000_000 * wave      // бит/с
            f.rateTxBps = 2_400_000 + 1_400_000 * (1 - wave)
            f.bytesRx = 2_061_584_302 + t * 6_000_000          // 1,92 ГБ
            f.bytesTx = 155_189_248 + t * 400_000              // 148 МБ
            f.streamsUp = 8
            f.streamActivity = (0..<16).map { i in
                i < 8 ? Float((sin(Double(tick + i * 2) / 2) + 1) / 2) : 0
            }
            f.rttMs = 38
            f.health = .healthy
        case .reconnecting:
            f.sessionSecs = 5_077 + t
            f.bytesRx = 2_061_584_302
            f.bytesTx = 155_189_248
            f.reconnectAttempt = 3
            f.reconnectNextDelaySecs = UInt32(8 - tick % 8)
            f.lastError = "network is unreachable (os error 51)"
        case .error:
            f.lastError = "Доступ отозван: сервер отклонил сертификат клиента"
        default:
            break
        }
        return f
    }

    static var logs: [LogFrame] {
        let lines: [(String, String)] = [
            ("INFO", "session started · profile «Нидерланды · relay»"),
            ("INFO", "route policy applied · ru-direct on · 3 manual cidrs"),
            ("ERROR", "stream 3: read timeout 15s · reopening"),
            ("INFO", "stream 3 up · rtt 38 ms"),
            ("INFO", "dns 1.1.1.1:853 (DoT) · 1 204 queries"),
            ("WARN", "network changed: Wi-Fi → Ethernet · reconnecting (attempt 1)"),
            ("INFO", "connecting · relay balancer.bikini-bottom.com:443"),
            ("INFO", "TLS 1.3 handshake ok · sni=tls.nl2.bikini-bottom.com"),
            ("INFO", "tunnel up · 8/8 streams · via relay"),
        ]
        let base = UInt64(Date().timeIntervalSince1970 * 1000) - 600_000
        return lines.enumerated().map { i, line in
            LogFrame(tsUnixMs: base + UInt64(i) * 67_000, level: line.0, msg: line.1)
        }
    }

    // MARK: - Launch

    /// Из `MenuBarExtra` label `.task`: открыть консоль; с -gsSnapshot —
    /// снять PNG и выйти.
    @MainActor
    static func start(openConsole: () -> Void) async {
        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { event in
            if event.type == .keyDown, event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "q" {
                exit(0)
            }
            return nil
        }
        if let theme {
            NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        }
        openConsole()
        guard let snapshotDir else { return }
        await snapshot(to: URL(fileURLWithPath: snapshotDir, isDirectory: true))
        exit(0)
    }

    @MainActor
    private static func snapshot(to requested: URL) async {
        // Песочница: писать можно только в свой контейнер.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(requested.lastPathComponent)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(1.5))
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("console") == true }) else {
            print("gsSnapshot: console window not found in \(NSApp.windows.map { $0.identifier?.rawValue ?? "-" })")
            return
        }
        window.setFrame(NSRect(x: 80, y: 80, width: 1100, height: 720), display: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let files: [SidebarChannel: String] = [
            .stream: "main", .roster: "servers", .tail: "logs", .admin: "admin", .setup: "settings",
        ]
        let admin = ProfilesStore.shared.activeProfile?.cachedIsAdmin == true
        for channel in SidebarChannel.visible(adminUnlocked: admin) {
            AppRouter.shared.select(channel)
            try? await Task.sleep(for: .seconds(1.2))
            capture(window, to: dir.appendingPathComponent("\(files[channel]!).png"))
        }

        // Попап меню-бара — offscreen, в своём окне вне экрана.
        let host = NSHostingView(rootView: LocalizedRoot {
            MenuBarPopover().gsAppEnvironment()
        })
        let popover = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 380, height: 636),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        popover.appearance = NSApp.appearance
        popover.contentView = host
        popover.orderFront(nil)
        try? await Task.sleep(for: .seconds(1))
        capture(popover, to: dir.appendingPathComponent("popover.png"))

        await snapshotWelcomeAndAbout(to: dir)
    }

    /// Мастер (welcome.png — первый шаг, welcome-<шаг>.png — остальные)
    /// и «О программе» (about.png) — offscreen, как попап.
    @MainActor
    private static func snapshotWelcomeAndAbout(to dir: URL) async {
        func offscreen(_ view: some View, size: NSSize, name: String) async {
            // Как окно со скрытым заголовком (мастер, «О программе») и ключевое —
            // иначе prominent-кнопки рисуются неактивными.
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSApp.appearance
            window.contentView = NSHostingView(rootView: LocalizedRoot { view.gsAppEnvironment() })
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(0.8))
            capture(window, to: dir.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }
        for step in OnboardingCoordinator.Step.allCases {
            await offscreen(WelcomeWindow(previewStep: step), size: NSSize(width: 720, height: 560),
                            name: step == .paste ? "welcome" : "welcome-\(step)")
        }
        await offscreen(AboutView().fixedSize(), size: NSSize(width: 340, height: 330), name: "about")
        // «Настройки» целиком, без прокрутки.
        await offscreen(SettingsView(), size: NSSize(width: 860, height: 1560), name: "settings-full")
        await offscreen(CommandPalette(), size: NSSize(width: 760, height: 560), name: "palette")
        // Подсказка после мастера: флаг — в volatile-домене, на диск не пишется.
        var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        args["menuBarHintPending"] = true
        UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
        await offscreen(MenuBarHint().frame(width: 720, height: 140), size: NSSize(width: 720, height: 140), name: "hint")
    }

    /// Снимок своего окна у window server — со стеклом, материалами и
    /// тулбаром; для собственных окон разрешение на запись экрана не нужно.
    /// CGWindowListCreateImage в SDK помечен obsolete, поэтому через dlsym;
    /// если символа не станет — cacheDisplay (без стекла и сайдбара).
    @MainActor
    private static func capture(_ window: NSWindow, to url: URL) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var image: CGImage?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let optionIncludingWindow: UInt32 = 1 << 3
            let ignoreFramingBestResolution: UInt32 = 1 << 0 | 1 << 3
            image = unsafeBitCast(sym, to: Capture.self)(
                .null, optionIncludingWindow, UInt32(window.windowNumber), ignoreFramingBestResolution
            )?.takeRetainedValue()
        }
        if image == nil, let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            image = rep.cgImage
        }
        guard let image,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil
        else {
            print("gsSnapshot: failed \(url.path)")
            return
        }
        print("gsSnapshot: \(url.path)")
    }
}
#endif
