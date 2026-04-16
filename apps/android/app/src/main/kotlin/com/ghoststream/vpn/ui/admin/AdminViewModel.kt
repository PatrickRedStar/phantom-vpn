package com.ghoststream.vpn.ui.admin

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.AdminHttpClient
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.VpnProfile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

data class ClientInfo(
    val name: String,
    val tunAddr: String,
    val fingerprint: String,
    val enabled: Boolean,
    val isAdmin: Boolean,
    val connected: Boolean,
    val bytesRx: Long,
    val bytesTx: Long,
    val createdAt: String,
    val lastSeenSecs: Long,
    val expiresAt: Long? = null,
)

data class ServerStatus(
    val uptimeSecs: Long,
    val sessionsActive: Int,
    val serverAddr: String,
    val exitIp: String? = null,
)

data class StatsSample(val ts: Long, val bytesRx: Long, val bytesTx: Long)
data class DestEntry(val ts: Long, val dst: String, val port: Int, val proto: String, val bytes: Long)

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
    private var http: OkHttpClient? = null
    private var fpRef: AdminHttpClient.ServerCertFpRef? = null
    private var profilesStore: ProfilesStore? = null
    private var profileId: String? = null

    /** Initialize client from a VpnProfile: derives gateway URL + builds mTLS client. */
    fun init(profile: VpnProfile, store: ProfilesStore) {
        profilesStore = store
        profileId = profile.id
        baseUrl = "https://${gatewayOf(profile.tunAddr)}:8080"
        try {
            val outcome = AdminHttpClient.build(
                certPemPath = profile.certPath,
                keyPemPath = profile.keyPath,
                pinnedFp = profile.cachedAdminServerCertFp,
            )
            http = outcome.client
            fpRef = outcome.serverCertFpRef
            refresh()
        } catch (e: Exception) {
            _error.value = "Ошибка инициализации mTLS: ${e.message}"
        }
    }

    private fun gatewayOf(tunCidr: String): String {
        val ip = tunCidr.substringBefore('/', tunCidr)
        val parts = ip.split('.')
        return if (parts.size == 4) "${parts[0]}.${parts[1]}.${parts[2]}.1" else "10.7.0.1"
    }

    private fun persistFpIfNeeded() {
        val store = profilesStore ?: return
        val id = profileId ?: return
        val fp = fpRef?.value ?: return
        val p = store.profiles.value.find { it.id == id } ?: return
        if (p.cachedAdminServerCertFp == fp) return
        store.updateProfile(p.copy(cachedAdminServerCertFp = fp))
    }

    fun refresh() {
        viewModelScope.launch {
            _loading.value = true
            _error.value = null
            try {
                _status.value = fetchStatus()
                _clients.value = fetchClients()
                persistFpIfNeeded()
            } catch (e: Exception) {
                val msg = e.message ?: "Ошибка подключения"
                _error.value = if (msg.contains("connect", true) || msg.contains("timeout", true) ||
                    msg.contains("refused", true) || msg.contains("unreachable", true))
                    "$msg\n\nAdmin API доступен только через VPN-туннель. Подключитесь к VPN и повторите."
                else msg
            } finally {
                _loading.value = false
            }
        }
    }

    fun createClient(name: String, expiresDays: Int? = null, isAdmin: Boolean = false) {
        viewModelScope.launch {
            _loading.value = true
            _error.value = null
            _newConnString.value = null
            try {
                val body = JSONObject().put("name", name).put("is_admin", isAdmin)
                if (expiresDays != null) body.put("expires_days", expiresDays)
                val result = apiPost("/api/clients", body.toString())
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
            try { apiDelete("/api/clients/$name"); refresh() }
            catch (e: Exception) { _error.value = e.message ?: "Ошибка удаления" }
        }
    }

    fun toggleEnabled(name: String, currentlyEnabled: Boolean) {
        viewModelScope.launch {
            try {
                val endpoint = if (currentlyEnabled) "/api/clients/$name/disable" else "/api/clients/$name/enable"
                apiPost(endpoint, "{}"); refresh()
            } catch (e: Exception) { _error.value = e.message ?: "Ошибка" }
        }
    }

    fun toggleAdmin(name: String, makeAdmin: Boolean) {
        viewModelScope.launch {
            try {
                apiPost("/api/clients/$name/admin", JSONObject().put("is_admin", makeAdmin).toString())
                refresh()
            } catch (e: Exception) { _error.value = e.message ?: "Ошибка" }
        }
    }

    fun getConnString(name: String) {
        viewModelScope.launch {
            try {
                val result = apiGet("/api/clients/$name/conn_string")
                _newConnString.value = result.optString("conn_string")
            } catch (e: Exception) { _error.value = e.message ?: "Ошибка" }
        }
    }

    fun clearNewConnString() { _newConnString.value = null }

    fun manageSubscription(name: String, action: String, days: Int? = null) {
        viewModelScope.launch {
            _loading.value = true
            _error.value = null
            try {
                val body = JSONObject().put("action", action)
                if (days != null) body.put("days", days)
                apiPost("/api/clients/$name/subscription", body.toString())
                refresh()
            } catch (e: Exception) {
                _error.value = e.message ?: "Ошибка"
                _loading.value = false
            }
        }
    }

    fun loadClientStats(name: String) {
        viewModelScope.launch {
            _selectedClient.value = name
            try {
                val arr = apiGetArray("/api/clients/$name/stats")
                _clientStats.value = (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    StatsSample(o.optLong("ts"), o.optLong("bytes_rx"), o.optLong("bytes_tx"))
                }
            } catch (e: Exception) { _error.value = e.message ?: "Ошибка" }
        }
    }

    fun loadClientLogs(name: String) {
        viewModelScope.launch {
            try {
                val arr = apiGetArray("/api/clients/$name/logs")
                _clientLogs.value = (0 until arr.length()).map { i ->
                    val o = arr.getJSONObject(i)
                    DestEntry(o.optLong("ts"), o.optString("dst"), o.optInt("port"),
                              o.optString("proto"), o.optLong("bytes"))
                }
            } catch (e: Exception) { _error.value = e.message ?: "Ошибка" }
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
                isAdmin = o.optBoolean("is_admin", false),
                connected = o.optBoolean("connected"),
                bytesRx = o.optLong("bytes_rx"),
                bytesTx = o.optLong("bytes_tx"),
                createdAt = o.optString("created_at"),
                lastSeenSecs = o.optLong("last_seen_secs"),
                expiresAt = o.optLong("expires_at", 0).takeIf { it > 0 },
            )
        }
    }

    private suspend fun apiGet(path: String): JSONObject = withContext(Dispatchers.IO) {
        val body = doRequest(Request.Builder().url("$baseUrl$path").get().build())
        JSONObject(body)
    }

    private suspend fun apiGetArray(path: String): JSONArray = withContext(Dispatchers.IO) {
        val body = doRequest(Request.Builder().url("$baseUrl$path").get().build())
        JSONArray(body)
    }

    private suspend fun apiPost(path: String, body: String): JSONObject = withContext(Dispatchers.IO) {
        val req = Request.Builder()
            .url("$baseUrl$path")
            .post(body.toRequestBody(JSON_MEDIA))
            .build()
        val resp = doRequest(req)
        if (resp.isBlank()) JSONObject() else JSONObject(resp)
    }

    private suspend fun apiDelete(path: String) = withContext(Dispatchers.IO) {
        doRequest(Request.Builder().url("$baseUrl$path").delete().build())
        Unit
    }

    private fun doRequest(req: Request): String {
        val client = http ?: error("AdminViewModel not initialized")
        client.newCall(req).execute().use { resp ->
            val body = resp.body?.string().orEmpty()
            if (!resp.isSuccessful) throw Exception("HTTP ${resp.code}: $body")
            return body
        }
    }

    companion object {
        private val JSON_MEDIA = "application/json; charset=utf-8".toMediaType()
    }
}

fun formatBytes(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "${"%.1f".format(bytes / 1024.0)} KB"
    else -> "${"%.1f".format(bytes / (1024.0 * 1024))} MB"
}
