package com.ghoststream.vpn.data

import android.content.Context
import android.net.wifi.WifiManager
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * Одноразовый HTTP-сервер для TV. Принимает один POST /pair и останавливается.
 * Живёт не дольше [TIMEOUT_MS] (5 минут).
 */
class PairingServer(
    private val token: String,
    private val context: Context,
) {

    private var serverSocket: ServerSocket? = null

    val port: Int get() = serverSocket?.localPort ?: 0

    companion object {
        const val TIMEOUT_MS = 300_000  // 5 минут

        fun generateToken(): String {
            val bytes = ByteArray(16)
            SecureRandom().nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }

    // v0.25.0: bind on the Wi-Fi interface IP, not 0.0.0.0. Conn-string is
    // LAN-only handoff; listening on all interfaces lets anything routed
    // here (VPN tap, ethernet, USB tether) probe /pair. Fallback to all-
    // interfaces if Wi-Fi unavailable (TV via ethernet), with warning log.
    private fun preferredBindAddress(): InetAddress? {
        val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val ipInt = wm?.connectionInfo?.ipAddress ?: return null
        if (ipInt == 0) return null
        // ipAddress is little-endian; convert to network-order bytes.
        val bytes = byteArrayOf(
            (ipInt and 0xFF).toByte(),
            (ipInt shr 8 and 0xFF).toByte(),
            (ipInt shr 16 and 0xFF).toByte(),
            (ipInt shr 24 and 0xFF).toByte(),
        )
        return runCatching { InetAddress.getByAddress(bytes) }.getOrNull()
    }

    /** Открывает случайный порт. Возвращает номер порта. */
    fun start(): Int {
        val bindAddr = preferredBindAddress()
        serverSocket = if (bindAddr != null) {
            ServerSocket(0, 50, bindAddr).also { it.soTimeout = TIMEOUT_MS }
        } else {
            Log.w("PairingServer", "no Wi-Fi IP, falling back to all-interfaces bind")
            ServerSocket(0).also { it.soTimeout = TIMEOUT_MS }
        }
        return serverSocket!!.localPort
    }

    /**
     * Блокирует до получения первого корректного запроса.
     * Возвращает conn_string из тела, либо Failure при ошибке/таймауте.
     */
    suspend fun awaitConnString(): Result<String> = withContext(Dispatchers.IO) {
        val server = serverSocket
            ?: return@withContext Result.failure(IllegalStateException("Сервер не запущен"))
        runCatching {
            server.accept().use { client ->
                val reader = BufferedReader(InputStreamReader(client.getInputStream()))
                val writer = PrintWriter(client.getOutputStream(), true)

                // Читаем строку запроса (игнорируем метод и путь)
                reader.readLine()

                // Читаем заголовки
                val headers = mutableMapOf<String, String>()
                var line = reader.readLine()
                while (!line.isNullOrEmpty()) {
                    val colon = line.indexOf(':')
                    if (colon > 0) {
                        headers[line.substring(0, colon).trim().lowercase()] =
                            line.substring(colon + 1).trim()
                    }
                    line = reader.readLine()
                }

                // Проверяем токен
                val auth = headers["authorization"] ?: ""
                // v0.25.0: constant-time compare; Kotlin String != is short-circuiting
                // per char which leaks a timing oracle for the token to LAN attackers.
                val expected = "Bearer $token".toByteArray(Charsets.UTF_8)
                val provided = auth.toByteArray(Charsets.UTF_8)
                val ok = expected.size == provided.size &&
                    MessageDigest.isEqual(expected, provided)
                if (!ok) {
                    val body = """{"error":"invalid token"}"""
                    writer.print(
                        "HTTP/1.1 401 Unauthorized\r\n" +
                            "Content-Type: application/json\r\n" +
                            "Content-Length: ${body.length}\r\n" +
                            "Connection: close\r\n\r\n$body"
                    )
                    writer.flush()
                    throw SecurityException("Неверный токен")
                }

                // Читаем тело
                val contentLength = headers["content-length"]?.toIntOrNull() ?: 0
                val bodyText = if (contentLength > 0) {
                    val chars = CharArray(contentLength)
                    reader.read(chars, 0, contentLength)
                    String(chars)
                } else ""

                val connString = JSONObject(bodyText).optString("conn_string", "")
                if (connString.isEmpty()) {
                    val body = """{"error":"missing conn_string"}"""
                    writer.print(
                        "HTTP/1.1 400 Bad Request\r\n" +
                            "Content-Type: application/json\r\n" +
                            "Content-Length: ${body.length}\r\n" +
                            "Connection: close\r\n\r\n$body"
                    )
                    writer.flush()
                    throw IllegalArgumentException("Нет conn_string в запросе")
                }

                val ok2 = """{"ok":true}"""
                writer.print(
                    "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: ${ok2.length}\r\n" +
                        "Connection: close\r\n\r\n$ok2"
                )
                writer.flush()
                connString
            }
        }.also { stop() }
    }

    fun stop() {
        runCatching { serverSocket?.close() }
        serverSocket = null
    }
}
