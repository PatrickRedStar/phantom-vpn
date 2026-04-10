package com.ghoststream.vpn.data

import android.util.Base64
import org.json.JSONObject
import java.io.File

object ConnStringParser {

    private val VALID_TRANSPORTS = setOf("quic", "h2", "auto")

    data class ParsedConfig(
        val addr: String,
        val sni: String,
        val tun: String,
        val cert: String,
        val key: String,
        val ca: String? = null,
        val adminUrl: String? = null,
        val adminToken: String? = null,
        val transport: String = "h2",
    )

    /**
     * Определяет транспорт из порта в addr.
     * Порт 8443 → quic, порт 9443 → h2.
     */
    private fun inferTransportFromPort(addr: String): String {
        val port = addr.substringAfterLast(':', "").substringBefore("/").toIntOrNull()
        return when (port) {
            8443 -> "quic"
            9443 -> "h2"
            else -> "h2" // default
        }
    }

    private fun normalizeTransport(raw: String?): String? {
        val transport = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
        return transport.takeIf { it in VALID_TRANSPORTS }
    }

    fun parse(input: String): Result<ParsedConfig> = runCatching {
        val trimmed = input.trim()

        val json = when {
            trimmed.startsWith("{") -> trimmed
            trimmed.matches(Regex("[A-Za-z0-9_\\-]+")) -> {
                val padded = trimmed + "=".repeat((4 - trimmed.length % 4) % 4)
                String(
                    Base64.decode(padded, Base64.URL_SAFE or Base64.NO_WRAP),
                    Charsets.UTF_8,
                )
            }
            else -> throw IllegalArgumentException("Неизвестный формат")
        }

        val obj = JSONObject(json)

        val adminObj = obj.optJSONObject("admin")
        val adminUrl   = adminObj?.optString("url")?.takeIf { it.isNotEmpty() }
        val adminToken = adminObj?.optString("token")?.takeIf { it.isNotEmpty() }

        val addr = obj.getString("addr")
        val transport = normalizeTransport(
            if (obj.has("transport") && !obj.isNull("transport")) obj.getString("transport") else null,
        )
            ?: inferTransportFromPort(addr)

        ParsedConfig(
            addr       = addr,
            sni        = obj.getString("sni"),
            tun        = obj.getString("tun"),
            cert       = obj.getString("cert"),
            key        = obj.getString("key"),
            ca         = if (obj.has("ca") && !obj.isNull("ca")) obj.getString("ca") else null,
            adminUrl   = adminUrl,
            adminToken = adminToken,
            transport  = transport,
        )
    }

    /**
     * Собирает connection string из профиля (обратная операция к parse).
     * Читает cert/key/ca с диска. Возвращает null при ошибке чтения файлов.
     */
    fun build(profile: VpnProfile): String? = runCatching {
        val cert = File(profile.certPath).readText()
        val key  = File(profile.keyPath).readText()
        val ca   = profile.caCertPath?.let { File(it).readText() }

        val json = JSONObject().apply {
            put("v",    1)
            put("addr", profile.serverAddr)
            put("sni",  profile.serverName)
            put("tun",  profile.tunAddr)
            put("cert", cert)
            put("key",  key)
            put("transport", profile.transport)
            if (ca != null) put("ca", ca)
            if (profile.adminUrl != null && profile.adminToken != null) {
                put("admin", JSONObject().apply {
                    put("url",   profile.adminUrl)
                    put("token", profile.adminToken)
                })
            }
        }

        Base64.encodeToString(
            json.toString().toByteArray(Charsets.UTF_8),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
    }.getOrNull()
}
