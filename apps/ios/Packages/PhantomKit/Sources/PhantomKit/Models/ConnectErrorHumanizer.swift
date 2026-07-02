import Foundation

/// Превращает сырой текст ошибки подключения (системный NE / Rust FFI /
/// внутренние `*Error`) в короткое человекочитаемое русское сообщение
/// для inline-баннера под кнопкой CONNECT.
///
/// Раньше `tunnel.lastError = error.localizedDescription` показывал
/// пользователю сырой англоязычный технический текст (P2-5 UX-аудита).
/// Маппинг по подстрокам — устойчив к тому, что конкретный тип ошибки
/// приходит из разных слоёв (NEVPNManager, PhantomBridge, ProviderError).
public enum ConnectErrorHumanizer {

    /// - Parameter raw: `error.localizedDescription` или текст из IPC.
    /// - Returns: русское сообщение; при незнакомой ошибке — общий текст
    ///   с сохранённым «техническим хвостом» для диагностики.
    public static func humanize(_ raw: String) -> String {
        let s = raw.lowercased()

        func has(_ needles: String...) -> Bool {
            needles.contains { s.contains($0) }
        }

        // Порядок важен: специфичные проверки раньше общих.
        if has("credentials missing", "cert/key", "re-import the ghs", "bridgeerror.encoding", "encode provider configuration") {
            return "Учётные данные профиля не найдены — переимпортируйте ghs://-ссылку в настройках."
        }
        if has("handshake timed out", "handshake timeout") {
            return "Сервер не ответил вовремя (таймаут рукопожатия). Проверьте доступность сервера и попробуйте снова."
        }
        if has("split-routing failed", "route computation", "no vpn routes") {
            return "Не удалось вычислить маршруты split-routing. Проверьте список прямых CIDR в настройках."
        }
        if has("tunnel start in progress", "connect already in progress") {
            return "Подключение уже выполняется — подождите."
        }
        if has("not approved", "awaiting", "user approval", "systemextension", "system extension") {
            return "Расширение сети не одобрено. Разрешите его в Системных настройках → Основные → Login Items и расширения → Сетевые расширения."
        }
        if has("no active session", "session is not active", "session not found", "session is unavailable") {
            return "Сессия VPN неактивна. Переподключитесь."
        }
        if has("importing keychain", "migration") {
            return "Идёт перенос данных из предыдущей версии — подождите пару секунд и попробуйте снова."
        }
        if has("network is down", "network is unreachable", "no network", "not connected to the internet", "offline") {
            return "Нет сети. Проверьте подключение к интернету."
        }
        if has("connection refused", "could not connect", "cannot connect", "connection reset", "econnrefused") {
            return "Сервер недоступен (соединение отклонено). Попробуйте другой профиль или позже."
        }
        if has("timed out", "timeout", "timed-out", "etimedout") {
            return "Истекло время ожидания. Проверьте сеть и доступность сервера."
        }
        if has("certificate", "mtls", "tls", "handshake failure", "bad certificate", "unauthorized", "401", "403") {
            return "Сервер отклонил сертификат (mTLS). Возможно, профиль устарел — переимпортируйте ghs://-ссылку."
        }
        if has("cancelled", "canceled", "superseded") {
            return "Операция отменена."
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Не удалось подключиться. Попробуйте ещё раз."
        }
        return "Не удалось подключиться: \(trimmed)"
    }
}
