package com.ghoststream.vpn.data

import android.util.Base64
import org.json.JSONObject

object ConnStringParser {

    data class ParsedConfig(
        val addr: String,
        val sni: String,
        val tun: String,
        val cert: String,
        val key: String,
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

        ParsedConfig(
            addr = obj.getString("addr"),
            sni  = obj.getString("sni"),
            tun  = obj.getString("tun"),
            cert = obj.getString("cert"),
            key  = obj.getString("key"),
        )
    }
}
