import Foundation

/// Каноничная логика фильтрации live-логов, вынесенная из SwiftUI-вьюх
/// в тестируемое место (паттерн `StatusBroadcastGate`/`MacStartupPolicy`).
///
/// До этого `TailViewFilter.normalize` (macOS app) и
/// `TunnelLogStore.normalizedLevel` держали ДВЕ рукописные копии одной
/// таблицы уровней — рассинхрон молча ломал бы фильтр. Теперь обе
/// делегируют сюда.
public enum LogFrameFilter {

    /// Нормализованные уровни, на которые маппятся сырые коды рантайма.
    public enum Level: String, CaseIterable, Sendable {
        case info, warn, error, debug, ok
    }

    /// Каноничная нормализация 3-символьных кодов рантайма (+legacy-алиасы)
    /// в стабильный ключ. Неизвестное → `.info`.
    public static func normalizedLevel(_ level: String) -> Level {
        switch level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "inf", "info":               return .info
        case "wrn", "warn", "warning":    return .warn
        case "err", "error":              return .error
        case "dbg", "debug", "trc", "trace": return .debug
        case "ok", "success":             return .ok
        default:                          return .info
        }
    }

    /// Совпадает ли фрейм с текстовым запросом. Пустой запрос → true.
    /// `useRegex` с невалидным паттерном обрабатывает вызывающая сторона
    /// (regex == nil → false).
    public static func matches(
        level: String,
        msg: String,
        category: String?,
        fields: [String: String]?,
        search: String,
        regex: NSRegularExpression?,
        useRegex: Bool
    ) -> Bool {
        guard !search.isEmpty else { return true }

        var haystack = "\(level) \(msg)"
        if let category { haystack.append(" \(category)") }
        if let fields, !fields.isEmpty {
            for (k, v) in fields {
                haystack.append(" \(k)=\(v)")
            }
        }

        guard useRegex else {
            return haystack.localizedCaseInsensitiveContains(search)
        }
        guard let regex else { return false }
        let range = NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }
}
