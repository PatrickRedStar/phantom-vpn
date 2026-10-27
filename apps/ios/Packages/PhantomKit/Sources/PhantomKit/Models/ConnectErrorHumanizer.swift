import Foundation

/// Превращает сырой текст ошибки подключения (системный NE / Rust FFI /
/// внутренние `*Error`) в короткое человекочитаемое сообщение (русское,
/// с `english: true` — английское) для inline-баннера под кнопкой CONNECT.
///
/// Раньше `tunnel.lastError = error.localizedDescription` показывал
/// пользователю сырой англоязычный технический текст (P2-5 UX-аудита).
/// Маппинг по подстрокам — устойчив к тому, что конкретный тип ошибки
/// приходит из разных слоёв (NEVPNManager, PhantomBridge, ProviderError).
public enum ConnectErrorHumanizer {

    /// - Parameters:
    ///   - raw: `error.localizedDescription` или текст из IPC.
    ///   - english: английский текст вместо русского (язык UI iOS).
    /// - Returns: короткое сообщение; при незнакомой ошибке — общий текст
    ///   с сохранённым «техническим хвостом» для диагностики.
    public static func humanize(_ raw: String, english: Bool = false) -> String {
        let s = raw.lowercased()

        func t(_ ru: String, _ en: String) -> String { english ? en : ru }

        func has(_ needles: String...) -> Bool {
            needles.contains { s.contains($0) }
        }

        // Порядок важен: специфичные проверки раньше общих.
        if has("credentials missing", "cert/key", "re-import the ghs", "bridgeerror.encoding", "encode provider configuration") {
            return t("Учётные данные профиля не найдены — переимпортируйте ghs://-ссылку в настройках.",
                     "Profile credentials not found — re-import the ghs:// link in Settings.")
        }
        if has("handshake timed out", "handshake timeout") {
            return t("Сервер не ответил вовремя (таймаут рукопожатия). Проверьте доступность сервера и попробуйте снова.",
                     "The server didn't answer in time (handshake timeout). Check that it's reachable and try again.")
        }
        if has("split-routing failed", "route computation", "no vpn routes") {
            return t("Не удалось вычислить маршруты split-routing. Проверьте список прямых CIDR в настройках.",
                     "Couldn't compute split-routing routes. Check the direct CIDR list in Settings.")
        }
        if has("tunnel start in progress", "connect already in progress") {
            return t("Подключение уже выполняется — подождите.",
                     "Already connecting — please wait.")
        }
        if has("not approved", "awaiting", "user approval", "systemextension", "system extension") {
            return t("Расширение сети не одобрено. Разрешите его в Системных настройках → Основные → Login Items и расширения → Сетевые расширения.",
                     "The network extension isn't approved. Allow it in System Settings → General → Login Items & Extensions → Network Extensions.")
        }
        if has("no active session", "session is not active", "session not found", "session is unavailable") {
            return t("Сессия VPN неактивна. Переподключитесь.",
                     "The VPN session isn't active. Reconnect.")
        }
        if has("importing keychain", "migration") {
            return t("Идёт перенос данных из предыдущей версии — подождите пару секунд и попробуйте снова.",
                     "Migrating data from the previous version — wait a few seconds and try again.")
        }
        if has("network is down", "network is unreachable", "no network", "not connected to the internet", "offline") {
            return t("Нет сети. Проверьте подключение к интернету.",
                     "No network. Check your internet connection.")
        }
        if has("connection refused", "could not connect", "cannot connect", "connection reset", "econnrefused") {
            return t("Сервер недоступен (соединение отклонено). Попробуйте другой профиль или позже.",
                     "Server unreachable (connection refused). Try another profile or later.")
        }
        if has("timed out", "timeout", "timed-out", "etimedout") {
            return t("Истекло время ожидания. Проверьте сеть и доступность сервера.",
                     "Timed out. Check the network and that the server is reachable.")
        }
        if has("certificate", "mtls", "tls", "handshake failure", "bad certificate", "unauthorized", "401", "403") {
            return t("Сервер отклонил сертификат (mTLS). Возможно, профиль устарел — переимпортируйте ghs://-ссылку.",
                     "The server rejected the certificate (mTLS). The profile may be outdated — re-import the ghs:// link.")
        }
        if has("cancelled", "canceled", "superseded") {
            return t("Операция отменена.",
                     "Cancelled.")
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return t("Не удалось подключиться. Попробуйте ещё раз.",
                     "Couldn't connect. Try again.")
        }
        return t("Не удалось подключиться: \(trimmed)",
                     "Couldn't connect: \(trimmed)")
    }

    /// Local-notification text for a fatal stop (ADR 0018): the cause in the
    /// title («VPN остановлен: доступ отозван»), what to do in the body.
    /// `raw` is the core's `last_error` (Russian reasons from `fatal_reason`).
    public static func fatalStop(
        _ raw: String,
        profileName: String,
        english: Bool = false
    ) -> (title: String, body: String) {
        let s = raw.lowercased()
        func t(_ ru: String, _ en: String) -> String { english ? en : ru }
        func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }

        let cause: String
        let body: String
        if has("доступ отозван", "revoked", "accessdenied", "access denied") {
            cause = t("доступ отозван", "access revoked")
            body = t("Сервер отклонил сертификат профиля \(profileName). Попросите новую ссылку у администратора.",
                     "The server rejected the certificate of profile \(profileName). Ask the admin for a new link.")
        } else if has("дату и время", "date and time", "not valid yet") {
            // Before «expired»: a wrong clock also looks like an expired server cert.
            cause = t("неверные дата и время", "wrong date and time")
            body = t("Сертификат сервера не подходит к текущей дате. Проверьте дату и время на устройстве и подключитесь снова.",
                     "The server certificate doesn't match the current date. Check the device date and time, then connect again.")
        } else if has("срок действия доступа истёк", "certificateexpired", "access expired") {
            cause = t("доступ истёк", "access expired")
            body = t("Срок доступа профиля \(profileName) закончился. Попросите администратора продлить подписку.",
                     "Access for profile \(profileName) has expired. Ask the admin to extend it.")
        } else {
            cause = t("ошибка", "error")
            body = humanize(raw, english: english)
        }
        return (t("VPN остановлен: \(cause)", "VPN stopped: \(cause)"), body)
    }
}
