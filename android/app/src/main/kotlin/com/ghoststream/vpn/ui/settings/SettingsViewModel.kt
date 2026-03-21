package com.ghoststream.vpn.ui.settings

import android.app.Application
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.data.VpnConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val preferencesStore = PreferencesStore(application)
    val routingRulesManager = RoutingRulesManager(application)

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

                // Save CA cert if present in connection string
                var caPath: String? = null
                if (parsed.ca != null) {
                    val caFile = File(ctx.filesDir, "ca.crt")
                    caFile.writeText(parsed.ca)
                    caPath = caFile.absolutePath
                }

                viewModelScope.launch {
                    preferencesStore.saveConfig(
                        VpnConfig(
                            serverAddr = parsed.addr,
                            serverName = parsed.sni,
                            insecure   = false,
                            certPath   = certFile.absolutePath,
                            keyPath    = keyFile.absolutePath,
                            caCertPath = caPath,
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

    // ── Routing ──────────────────────────────────────────────────────

    private val _downloadStatus = MutableStateFlow("")
    val downloadStatus: StateFlow<String> = _downloadStatus

    fun setSplitRouting(enabled: Boolean) {
        viewModelScope.launch {
            preferencesStore.saveConfig(config.value.copy(splitRouting = enabled))
        }
    }

    fun toggleDirectCountry(code: String) {
        viewModelScope.launch {
            val current = config.value.directCountries.toMutableList()
            if (code in current) current.remove(code) else current.add(code)
            preferencesStore.saveConfig(config.value.copy(directCountries = current))
        }
    }

    fun downloadCountryRules(code: String) {
        viewModelScope.launch {
            _downloadStatus.value = "Загрузка $code..."
            routingRulesManager.downloadRuleList(code).fold(
                onSuccess = { size ->
                    _downloadStatus.value = "$code загружен (${size / 1024} КБ)"
                },
                onFailure = { e ->
                    _downloadStatus.value = "Ошибка загрузки $code: ${e.message}"
                },
            )
        }
    }

    fun downloadAllSelected() {
        viewModelScope.launch {
            val codes = config.value.directCountries.ifEmpty {
                listOf("ru") // default
            }
            _downloadStatus.value = "Загрузка ${codes.joinToString(", ")}..."
            var ok = 0
            for (code in codes) {
                routingRulesManager.downloadRuleList(code).fold(
                    onSuccess = { ok++ },
                    onFailure = {},
                )
            }
            _downloadStatus.value = "Загружено $ok/${codes.size} списков"
        }
    }

    // ── Per-app ─────────────────────────────────────────────────────

    data class AppInfo(
        val packageName: String,
        val label: String,
        val isSystem: Boolean,
    )

    private val _installedApps = MutableStateFlow<List<AppInfo>>(emptyList())
    val installedApps: StateFlow<List<AppInfo>> = _installedApps

    fun loadInstalledApps() {
        if (_installedApps.value.isNotEmpty()) return
        viewModelScope.launch {
            val pm = getApplication<Application>().packageManager
            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                .map { info ->
                    AppInfo(
                        packageName = info.packageName,
                        label = pm.getApplicationLabel(info).toString(),
                        isSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0,
                    )
                }
                .sortedWith(compareBy({ it.isSystem }, { it.label.lowercase() }))
            _installedApps.value = apps
        }
    }

    fun setPerAppMode(mode: String) {
        viewModelScope.launch {
            preferencesStore.saveConfig(config.value.copy(perAppMode = mode))
        }
    }

    fun togglePerApp(packageName: String) {
        viewModelScope.launch {
            val current = config.value.perAppList.toMutableList()
            if (packageName in current) current.remove(packageName) else current.add(packageName)
            preferencesStore.saveConfig(config.value.copy(perAppList = current))
        }
    }
}
