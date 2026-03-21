package com.ghoststream.vpn.ui.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.VpnConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val preferencesStore = PreferencesStore(application)

    val config: StateFlow<VpnConfig> = preferencesStore.config
        .stateIn(viewModelScope, SharingStarted.Eagerly, VpnConfig())

    val theme: StateFlow<String> = preferencesStore.theme
        .stateIn(viewModelScope, SharingStarted.Eagerly, "system")

    private val _connString = MutableStateFlow("")
    val connString: StateFlow<String> = _connString

    private val _importStatus = MutableStateFlow("")
    val importStatus: StateFlow<String> = _importStatus

    fun setConnString(value: String) {
        _connString.value = value
    }

    fun importConfig() {
        val input = _connString.value.trim()
        if (input.isEmpty()) {
            _importStatus.value = "Вставьте строку подключения"
            return
        }

        ConnStringParser.parse(input).fold(
            onSuccess = { parsed ->
                val ctx = getApplication<Application>()
                val certFile = File(ctx.filesDir, "client.crt")
                val keyFile  = File(ctx.filesDir, "client.key")
                certFile.writeText(parsed.cert)
                keyFile.writeText(parsed.key)

                viewModelScope.launch {
                    preferencesStore.saveConfig(
                        VpnConfig(
                            serverAddr = parsed.addr,
                            serverName = parsed.sni,
                            insecure   = false,
                            certPath   = certFile.absolutePath,
                            keyPath    = keyFile.absolutePath,
                            tunAddr    = parsed.tun,
                            dnsServers = config.value.dnsServers,
                        ),
                    )
                }

                _connString.value = ""
                _importStatus.value = "Импортировано · ${parsed.addr} · tun ${parsed.tun}"
            },
            onFailure = {
                _importStatus.value = "Ошибка: ${it.message}"
            },
        )
    }

    fun setInsecure(insecure: Boolean) {
        viewModelScope.launch {
            preferencesStore.saveConfig(config.value.copy(insecure = insecure))
        }
    }

    fun setTheme(theme: String) {
        viewModelScope.launch {
            preferencesStore.setTheme(theme)
        }
    }

    fun setDnsServers(servers: List<String>) {
        viewModelScope.launch {
            preferencesStore.saveConfig(config.value.copy(dnsServers = servers))
        }
    }
}
