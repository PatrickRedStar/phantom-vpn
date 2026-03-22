package com.ghoststream.vpn.data

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.PrintWriter
import java.net.ServerSocket
import java.security.SecureRandom

/**
 * Одноразовый HTTP-сервер для TV. Принимает один POST /pair и останавливается.
 * Живёт не дольше [TIMEOUT_MS] (5 минут).
 */
class PairingServer(private val token: String) {

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

    /** Открывает случайный порт. Возвращает номер порта. */
    fun start(): Int {
        serverSocket = ServerSocket(0).also { it.soTimeout = TIMEOUT_MS }
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
                if (auth != "Bearer $token") {
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

                val ok = """{"ok":true}"""
                writer.print(
                    "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: ${ok.length}\r\n" +
                        "Connection: close\r\n\r\n$ok"
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
