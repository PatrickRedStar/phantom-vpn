package com.ghoststream.vpn.data

import android.util.Base64
import org.json.JSONObject
import java.io.File

object ConnStringParser {

    data class ParsedConfig(
        val addr: String,
        val sni: String,
        val tun: String,
        val cert: String,
        val key: String,
        val ca: String? = null,
        val adminUrl: String? = null,
        val adminToken: String? = null,
    )

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

        ParsedConfig(
            addr       = obj.getString("addr"),
            sni        = obj.getString("sni"),
            tun        = obj.getString("tun"),
            cert       = obj.getString("cert"),
            key        = obj.getString("key"),
            ca         = obj.optString("ca", null),
            adminUrl   = adminUrl,
            adminToken = adminToken,
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
