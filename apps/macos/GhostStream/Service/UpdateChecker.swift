//
//  UpdateChecker.swift
//  GhostStream (macOS)
//
//  ADR 0022: сравниваем свою версию с последним релизом на GitHub и
//  показываем «Доступна версия X — Скачать». DMG пользователь ставит сам.
//  Проверка при запуске и раз в сутки (если не выключена в «Настройках»);
//  сетевые ошибки молча игнорируются.
//

import Foundation
import Observation

@MainActor
@Observable
final class UpdateChecker {

    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        /// Что скачивать: DMG релиза, а без него — страница релиза.
        let url: URL
        /// «Что нового» — страница релиза.
        let notes: URL
    }

    /// Последний релиз, если он новее установленной версии.
    private(set) var available: Release?
    private(set) var checking = false
    private(set) var lastCheck: Date?
    /// Крестик на баннере скрывает эту версию насовсем; следующая покажется.
    /// Только флаг UI — в UserDefaults приложения, не в App Group.
    private var dismissedVersion = UserDefaults.standard.string(forKey: UpdateChecker.dismissedKey)
    var bannerDismissed: Bool { available?.version == dismissedVersion }

    /// Тумблер «Проверять автоматически».
    var autoCheck = UserDefaults.standard.object(forKey: UpdateChecker.autoCheckKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey)
            if autoCheck {
                start()
            } else {
                loop?.cancel()
                loop = nil
            }
        }
    }

    private static let dismissedKey = "updateBannerDismissedVersion"
    private static let autoCheckKey = "updateAutoCheck"

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    nonisolated static let currentBuild =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"

    private static let latestURL =
        URL(string: "https://api.github.com/repos/PatrickRedStar/ghoststream-releases/releases/latest")!

    @ObservationIgnored private var loop: Task<Void, Never>?

    private init() {
        #if DEBUG
        _ = Self.selfCheck
        #endif
    }

    /// Проверка при запуске и дальше раз в сутки.
    func start() {
        #if DEBUG
        if let release = DebugDemo.fakeRelease {
            available = release
            lastCheck = Date()
            return
        }
        #endif
        guard autoCheck, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }

        var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = try? JSONDecoder().decode(LatestRelease.self, from: data),
              let page = URL(string: latest.html_url)
        else { return }

        lastCheck = Date()
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        let dmg = latest.assets?.first { $0.name.hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browser_download_url) }
        available = Self.isNewer(version, than: Self.currentVersion)
            ? Release(version: version, url: dmg ?? page, notes: page) : nil
    }

    func dismissBanner() {
        dismissedVersion = available?.version
        UserDefaults.standard.set(dismissedVersion, forKey: Self.dismissedKey)
    }

    /// Покомпонентно числами: «0.29.10» новее «0.29.9»; хвосты вида «-beta» отбрасываются.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private struct LatestRelease: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]?

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    #if DEBUG
    private static let selfCheck: Void = {
        assert(isNewer("0.29.10", than: "0.29.9"))
        assert(isNewer("1.0", than: "0.99.9"))
        assert(!isNewer("0.29.0", than: "0.29.0"))
        assert(!isNewer("0.29.1-beta", than: "0.29.1"))
        assert(!isNewer("0.28.9", than: "0.29"))
    }()
    #endif
}
