package com.ghoststream.vpn.ui.admin

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

data class ClientInfo(
    val name: String,
    val tunAddr: String,
    val fingerprint: String,
    val enabled: Boolean,
    val connected: Boolean,
    val bytesRx: Long,
    val bytesTx: Long,
    val createdAt: String,
    val lastSeenSecs: Long,
)

data class ServerStatus(
    val uptimeSecs: Long,
    val sessionsActive: Int,
    val serverAddr: String,
    val exitIp: String? = null,
)

data class StatsSample(
    val ts: Long,
    val bytesRx: Long,
    val bytesTx: Long,
)

data class DestEntry(
    val ts: Long,
    val dst: String,
    val port: Int,
    val proto: String,
    val bytes: Long,
)

class AdminViewModel : ViewModel() {

    private val _status = MutableStateFlow<ServerStatus?>(null)
    val status: StateFlow<ServerStatus?> = _status

    private val _clients = MutableStateFlow<List<ClientInfo>>(emptyList())
    val clients: StateFlow<List<ClientInfo>> = _clients

    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading

    private val _error = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = _error

    private val _newConnString = MutableStateFlow<String?>(null)
    val newConnString: StateFlow<String?> = _newConnString

    private val _clientStats = MutableStateFlow<List<StatsSample>>(emptyList())
    val clientStats: StateFlow<List<StatsSample>> = _clientStats

    private val _clientLogs = MutableStateFlow<List<DestEntry>>(emptyList())
    val clientLogs: StateFlow<List<DestEntry>> = _clientLogs

    private val _selectedClient = MutableStateFlow<String?>(null)
    val selectedClient: StateFlow<String?> = _selectedClient

    private var baseUrl: String = ""
    private var token: String = ""

    fun init(adminUrl: String, adminToken: String) {
        baseUrl = adminUrl.trimEnd('/')
        token = adminToken
        refresh()
    }

    fun refresh() {
        viewModelScope.launch {
            _loading.value = true
            _error.value = null
            try {
                _status.value = fetchStatus()
                _clients.value = fetchClients()
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка подключения"
            } finally {
                _loading.value = false
            }
        }
    }

    fun createClient(name: String) {
        viewModelScope.launch {
            _loading.value = true
            _error.value = null
            _newConnString.value = null
            try {
                val body = JSONObject().put("name", name).toString()
                val result = apiPost("/api/clients", body)
                _newConnString.value = result.optString("conn_string")
                refresh()
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка создания клиента"
                _loading.value = false
            }
        }
    }

    fun deleteClient(name: String) {
        viewModelScope.launch {
            try {
                apiDelete("/api/clients/$name")
                refresh()
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка удаления"
            }
        }
    }

    fun toggleEnabled(name: String, currentlyEnabled: Boolean) {
        viewModelScope.launch {
            try {
                val endpoint = if (currentlyEnabled) "/api/clients/$name/disable" else "/api/clients/$name/enable"
                apiPost(endpoint, "{}")
                refresh()
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка"
            }
        }
    }

    fun getConnString(name: String) {
        viewModelScope.launch {
            try {
                val result = apiGet("/api/clients/$name/conn_string")
                _newConnString.value = result.optString("conn_string")
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка получения строки подключения"
            }
        }
    }

    fun clearNewConnString() { _newConnString.value = null }

    fun loadClientStats(name: String) {
        viewModelScope.launch {
            _selectedClient.value = name
            try {
                val arr = apiGetArray("/api/clients/$name/stats")
                _clientStats.value = (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    StatsSample(
                        ts = o.optLong("ts"),
                        bytesRx = o.optLong("bytes_rx"),
                        bytesTx = o.optLong("bytes_tx"),
                    )
                }
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка загрузки статистики"
            }
        }
    }

    fun loadClientLogs(name: String) {
        viewModelScope.launch {
            try {
                val arr = apiGetArray("/api/clients/$name/logs")
                _clientLogs.value = (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    DestEntry(
                        ts = o.optLong("ts"),
                        dst = o.optString("dst"),
                        port = o.optInt("port"),
                        proto = o.optString("proto"),
                        bytes = o.optLong("bytes"),
                    )
                }
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка загрузки логов"
            }
        }
    }

    fun clearClientDetails() {
        _selectedClient.value = null
        _clientStats.value = emptyList()
        _clientLogs.value = emptyList()
    }

    private suspend fun fetchStatus(): ServerStatus = withContext(Dispatchers.IO) {
        val obj = apiGet("/api/status")
        ServerStatus(
            uptimeSecs = obj.optLong("uptime_secs"),
            sessionsActive = obj.optInt("sessions_active"),
            serverAddr = obj.optString("server_addr"),
            exitIp = obj.optString("exit_ip").takeIf { it.isNotEmpty() && it != "null" },
        )
    }

    private suspend fun fetchClients(): List<ClientInfo> = withContext(Dispatchers.IO) {
        val arr = apiGetArray("/api/clients")
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            ClientInfo(
                name = o.optString("name"),
                tunAddr = o.optString("tun_addr"),
                fingerprint = o.optString("fingerprint"),
                enabled = o.optBoolean("enabled", true),
                connected = o.optBoolean("connected"),
                bytesRx = o.optLong("bytes_rx"),
                bytesTx = o.optLong("bytes_tx"),
                createdAt = o.optString("created_at"),
                lastSeenSecs = o.optLong("last_seen_secs"),
            )
        }
    }

    private suspend fun apiGet(path: String): JSONObject = withContext(Dispatchers.IO) {
        val conn = openConn("GET", path)
        val code = conn.responseCode
        val body = conn.inputStream.bufferedReader().readText()
        conn.disconnect()
        if (code != 200) throw Exception("HTTP $code: $body")
        JSONObject(body)
    }

    private suspend fun apiGetArray(path: String): JSONArray = withContext(Dispatchers.IO) {
        val conn = openConn("GET", path)
        val code = conn.responseCode
        val body = conn.inputStream.bufferedReader().readText()
        conn.disconnect()
        if (code != 200) throw Exception("HTTP $code: $body")
        JSONArray(body)
    }

    private suspend fun apiPost(path: String, body: String): JSONObject = withContext(Dispatchers.IO) {
        val conn = openConn("POST", path)
        conn.doOutput = true
        conn.setRequestProperty("Content-Type", "application/json")
        OutputStreamWriter(conn.outputStream).use { it.write(body) }
        val code = conn.responseCode
        val resp = try { conn.inputStream.bufferedReader().readText() }
                   catch (_: Exception) { conn.errorStream?.bufferedReader()?.readText() ?: "" }
        conn.disconnect()
        if (code !in 200..299) throw Exception("HTTP $code: $resp")
        if (resp.isBlank()) JSONObject() else JSONObject(resp)
    }

    private suspend fun apiDelete(path: String) = withContext(Dispatchers.IO) {
        val conn = openConn("DELETE", path)
        val code = conn.responseCode
        conn.disconnect()
        if (code !in 200..299) throw Exception("HTTP $code")
    }

    private fun openConn(method: String, path: String): HttpURLConnection {
        val url = URL("$baseUrl$path")
        val conn = url.openConnection() as HttpURLConnection
        conn.requestMethod = method
        conn.setRequestProperty("Authorization", "Bearer $token")
        conn.connectTimeout = 5000
        conn.readTimeout = 10000
        return conn
    }
}

fun formatBytes(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "${"%.1f".format(bytes / 1024.0)} KB"
    else -> "${"%.1f".format(bytes / (1024.0 * 1024))} MB"
}
