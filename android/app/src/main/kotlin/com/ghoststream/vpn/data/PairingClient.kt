package com.ghoststream.vpn.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

data class PairingPayload(
    val ip: String,
    val port: Int,
    val token: String,
)

object PairingClient {

    /**
     * Парсит QR-код типа gs-pair, возвращает null если это не pairing QR.
     */
    fun parsePairingQr(input: String): PairingPayload? = runCatching {
        val json = JSONObject(input.trim())
        if (json.optString("type") != "gs-pair") return null
        PairingPayload(
            ip    = json.getString("ip"),
            port  = json.getInt("port"),
            token = json.getString("token"),
        )
    }.getOrNull()

    /**
     * Отправляет connection string на TV.
     */
    suspend fun send(payload: PairingPayload, connString: String): Result<Unit> =
        withContext(Dispatchers.IO) {
            runCatching {
                val url = URL("http://${payload.ip}:${payload.port}/pair")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.setRequestProperty("Authorization", "Bearer ${payload.token}")
                conn.setRequestProperty("Content-Type", "application/json")
                conn.doOutput = true
                conn.connectTimeout = 5_000
                conn.readTimeout = 10_000

                val body = JSONObject().put("conn_string", connString).toString().toByteArray()
                conn.outputStream.use { it.write(body) }

                val code = conn.responseCode
                conn.disconnect()
                if (code != 200) throw RuntimeException("HTTP $code")
            }
        }
}
