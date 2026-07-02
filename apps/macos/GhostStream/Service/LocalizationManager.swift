//
//  LocalizationManager.swift
//  GhostStream (macOS)
//
//  Живое переключение языка без перезапуска приложения.
//
//  Почему это нужно: весь UI использует String(localized:), который
//  резолвит строку по `Bundle.main`, а язык бандла фиксируется ОДИН раз
//  при старте по `AppleLanguages`. Поэтому смена языка через
//  `AppleLanguages` раньше требовала рестарта. Здесь мы держим бандл
//  выбранного `.lproj` и резолвим строки через него в рантайме, а смена
//  языка триггерит перерисовку дерева (см. `LocalizedRoot` + `.id`).
//
//  Все вызовы `String(localized: "key")` заменены на `L("key")`.
//

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class LocalizationManager {

    public static let shared = LocalizationManager()

    /// nil = системный язык; "en"/"ru" = принудительный.
    public private(set) var language: String?

    /// Бандл выбранного `.lproj`. Стор-проперти под @Observable —
    /// чтение внутри `string(_:)` из view-body устанавливает зависимость,
    /// так что смена бандла перерисовывает потребителей.
    private var bundle: Bundle = .main

    private let defaults = UserDefaults(suiteName: "group.com.ghoststream.client")
        ?? .standard
    private let key = "language_override"

    private init() {
        language = defaults.string(forKey: key)
        rebuildBundle()
    }

    /// Сменить язык вживую. Персистится в тот же ключ, что и
    /// `PreferencesStore.languageOverride`.
    public func setLanguage(_ code: String?) {
        language = code
        if let code { defaults.set(code, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        rebuildBundle()
    }

    private func rebuildBundle() {
        if let language,
           let path = Bundle.main.path(forResource: language, ofType: "lproj"),
           let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }

    /// Резолв ключа против активного бандла.
    public func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
}

/// Замена `String(localized:)`. Резолвит против активного языка
/// `LocalizationManager` — смена языка обновляет результат без рестарта.
@MainActor
public func L(_ key: String) -> String {
    LocalizationManager.shared.string(key)
}

/// Обёртка корня окна: перерисовывает всё поддерево при смене языка
/// (через `.id`), чтобы все `L(...)` перерезолвились мгновенно.
public struct LocalizedRoot<Content: View>: View {
    @State private var loc = LocalizationManager.shared
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .environment(loc)
            .id(loc.language ?? "__system__")
    }
}
