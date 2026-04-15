package com.ghoststream.vpn.ui.pairing

import android.app.Application
import android.content.Context
import android.net.wifi.WifiManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PairingServer
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.VpnProfile
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import java.net.NetworkInterface

sealed class TvPairingState {
    object Idle : TvPairingState()
    data class Ready(val qrJson: String) : TvPairingState()
    object Received : TvPairingState()
    object Timeout : TvPairingState()
    data class Error(val message: String) : TvPairingState()
}

class TvPairingViewModel(application: Application) : AndroidViewModel(application) {

    private val _state = MutableStateFlow<TvPairingState>(TvPairingState.Idle)
    val state: StateFlow<TvPairingState> = _state

    private var server: PairingServer? = null
    private var timeoutJob: Job? = null

    init { start() }

    fun start() {
        server?.stop()
        timeoutJob?.cancel()
        server = null
        _state.value = TvPairingState.Idle

        val ip = getLocalIp() ?: run {
            _state.value = TvPairingState.Error("Устройство не подключено к WiFi")
            return
        }

        val token = PairingServer.generateToken()
        val pairingServer = PairingServer(token)
        val port = pairingServer.start()
        server = pairingServer

        val qrJson = JSONObject().apply {
            put("type", "gs-pair")
            put("ip", ip)
            put("port", port)
            put("token", token)
        }.toString()

        _state.value = TvPairingState.Ready(qrJson)

        timeoutJob = viewModelScope.launch {
            delay(PairingServer.TIMEOUT_MS.toLong())
            if (_state.value is TvPairingState.Ready) {
                pairingServer.stop()
                _state.value = TvPairingState.Timeout
            }
        }

        viewModelScope.launch {
            val result = pairingServer.awaitConnString()
            timeoutJob?.cancel()
            if (_state.value !is TvPairingState.Ready) return@launch

            result.fold(
                onSuccess = { connString ->
                    importConnString(connString)
                },
                onFailure = {
                    _state.value = TvPairingState.Error(it.message ?: "Ошибка")
                },
            )
        }
    }

    private fun importConnString(connString: String) {
        val app = getApplication<Application>()
        ConnStringParser.parse(connString).fold(
            onSuccess = { parsed ->
                val id = java.util.UUID.randomUUID().toString()
                val profileDir = File(app.filesDir, "profiles/$id").also { it.mkdirs() }
                val certFile = File(profileDir, "client.crt").also { it.writeText(parsed.cert) }
                val keyFile  = File(profileDir, "client.key").also { it.writeText(parsed.key) }
                ProfilesStore.getInstance(app).addProfile(
                    VpnProfile(
                        id         = id,
                        name       = parsed.sni.substringBefore(".").replaceFirstChar { it.uppercase() }
                                         .ifEmpty { "Подключение" },
                        serverAddr = parsed.addr,
                        serverName = parsed.sni,
                        insecure   = false,
                        certPath   = certFile.absolutePath,
                        keyPath    = keyFile.absolutePath,
                        tunAddr    = parsed.tun,
                    ),
                )
                _state.value = TvPairingState.Received
            },
            onFailure = {
                _state.value = TvPairingState.Error("Неверная строка подключения: ${it.message}")
            },
        )
    }

    private fun getLocalIp(): String? {
        // Сначала пробуем WifiManager
        @Suppress("DEPRECATION")
        val wm = getApplication<Application>().getSystemService(Context.WIFI_SERVICE) as? WifiManager
        @Suppress("DEPRECATION")
        val wifiIp = wm?.connectionInfo?.ipAddress?.takeIf { it != 0 }?.let { ip ->
            "${ip and 0xff}.${ip shr 8 and 0xff}.${ip shr 16 and 0xff}.${ip shr 24 and 0xff}"
        }
        if (wifiIp != null) return wifiIp

        // Фолбек: сканируем сетевые интерфейсы
        return runCatching {
            NetworkInterface.getNetworkInterfaces()?.asSequence()
                ?.flatMap { it.inetAddresses.asSequence() }
                ?.filter { !it.isLoopbackAddress && !it.hostAddress.isNullOrEmpty() && !it.hostAddress!!.contains(':') }
                ?.map { it.hostAddress!! }
                ?.firstOrNull { it.startsWith("192.") || it.startsWith("10.") || it.startsWith("172.") }
        }.getOrNull()
    }

    override fun onCleared() {
        super.onCleared()
        server?.stop()
        timeoutJob?.cancel()
    }
}
