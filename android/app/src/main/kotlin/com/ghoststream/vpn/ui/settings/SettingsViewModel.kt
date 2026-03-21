package com.ghoststream.vpn.ui.settings

import android.app.Application
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.data.VpnConfig
import com.ghoststream.vpn.data.VpnProfile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.File

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val preferencesStore = PreferencesStore(application)
    val profilesStore = ProfilesStore.getInstance(application)
    val routingRulesManager = RoutingRulesManager(application)

    val profiles: StateFlow<List<VpnProfile>> = profilesStore.profiles
    val activeProfileId: StateFlow<String?> = profilesStore.activeId

    // Combined config: active profile server fields + global DNS/routing/per-app settings
    val config: StateFlow<VpnConfig> = combine(
        profilesStore.profiles,
        profilesStore.activeId,
        preferencesStore.config,
    ) { profiles, activeId, prefs ->
        val p = profiles.find { it.id == activeId } ?: profiles.firstOrNull()
        VpnConfig(
            serverAddr      = p?.serverAddr ?: "",
            serverName      = p?.serverName ?: "",
            insecure        = p?.insecure ?: false,
            certPath        = p?.certPath ?: "",
            keyPath         = p?.keyPath ?: "",
            caCertPath      = p?.caCertPath,
            tunAddr         = p?.tunAddr ?: "10.7.0.2/24",
            dnsServers      = prefs.dnsServers,
            splitRouting    = prefs.splitRouting,
            directCountries = prefs.directCountries,
            perAppMode      = prefs.perAppMode,
            perAppList      = prefs.perAppList,
        )
    }.stateIn(viewModelScope, SharingStarted.Eagerly, VpnConfig())

    val theme: StateFlow<String> = preferencesStore.theme
        .stateIn(viewModelScope, SharingStarted.Eagerly, "system")

    // ── Import dialog state ───────────────────────────────────────────────────

    private val _pendingConnString = MutableStateFlow("")
    val pendingConnString: StateFlow<String> = _pendingConnString

    private val _pendingName = MutableStateFlow("")
    val pendingName: StateFlow<String> = _pendingName

    private val _importStatus = MutableStateFlow("")
    val importStatus: StateFlow<String> = _importStatus

    fun setPendingConnString(value: String) { _pendingConnString.value = value }
    fun setPendingName(value: String)       { _pendingName.value = value }

    fun importConfig() {
        val input = _pendingConnString.value.trim()
        if (input.isEmpty()) {
            _importStatus.value = "Вставьте строку подключения"
            return
        }

        ConnStringParser.parse(input).fold(
            onSuccess = { parsed ->
                val ctx = getApplication<Application>()
                val id = java.util.UUID.randomUUID().toString()
                val profileDir = File(ctx.filesDir, "profiles/$id").also { it.mkdirs() }

                val certFile = File(profileDir, "client.crt")
                val keyFile  = File(profileDir, "client.key")
                certFile.writeText(parsed.cert)
                keyFile.writeText(parsed.key)

                var caPath: String? = null
                if (parsed.ca != null) {
                    val caFile = File(profileDir, "ca.crt")
                    caFile.writeText(parsed.ca)
                    caPath = caFile.absolutePath
                }

                val name = _pendingName.value.trim().ifEmpty {
                    parsed.sni.substringBefore(".").replaceFirstChar { it.uppercase() }
                        .ifEmpty { "Подключение" }
                }

                profilesStore.addProfile(
                    VpnProfile(
                        id         = id,
                        name       = name,
                        serverAddr = parsed.addr,
                        serverName = parsed.sni,
                        insecure   = false,
                        certPath   = certFile.absolutePath,
                        keyPath    = keyFile.absolutePath,
                        caCertPath = caPath,
                        tunAddr    = parsed.tun,
                    ),
                )

                _pendingConnString.value = ""
                _pendingName.value = ""
                _importStatus.value = "Добавлено: $name · ${parsed.addr}"
            },
            onFailure = {
                _importStatus.value = "Ошибка: ${it.message}"
            },
        )
    }

    fun deleteProfile(id: String) = profilesStore.deleteProfile(id)

    fun setActiveProfile(id: String) = profilesStore.setActiveId(id)

    fun renameProfile(id: String, name: String) {
        val profile = profilesStore.profiles.value.find { it.id == id } ?: return
        profilesStore.updateProfile(profile.copy(name = name.trim().ifEmpty { profile.name }))
    }

    fun setInsecure(insecure: Boolean) {
        val profile = profilesStore.getActiveProfile() ?: return
        profilesStore.updateProfile(profile.copy(insecure = insecure))
    }

    fun setTheme(theme: String) {
        viewModelScope.launch { preferencesStore.setTheme(theme) }
    }

    fun setDnsServers(servers: List<String>) {
        viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(dnsServers = servers)) }
    }

    // ── Routing ──────────────────────────────────────────────────────────────

    private val _downloadedRules = MutableStateFlow<Map<String, RoutingRulesManager.RuleInfo>>(emptyMap())
    val downloadedRules: StateFlow<Map<String, RoutingRulesManager.RuleInfo>> = _downloadedRules

    private val _downloading = MutableStateFlow<Set<String>>(emptySet())
    val downloading: StateFlow<Set<String>> = _downloading

    private val _downloadStatus = MutableStateFlow("")
    val downloadStatus: StateFlow<String> = _downloadStatus

    init {
        refreshDownloadedRules()
        migrateLegacyIfNeeded()
    }

    private fun migrateLegacyIfNeeded() {
        if (profilesStore.profiles.value.isNotEmpty()) return
        viewModelScope.launch {
            val old = preferencesStore.config.first()
            profilesStore.migrateFromLegacy(
                serverAddr = old.serverAddr,
                serverName = old.serverName,
                insecure   = old.insecure,
                certPath   = old.certPath,
                keyPath    = old.keyPath,
                caCertPath = old.caCertPath,
                tunAddr    = old.tunAddr,
            )
        }
    }

    private fun refreshDownloadedRules() {
        _downloadedRules.value = routingRulesManager.getDownloadedRules().associateBy { it.code }
    }

    fun setSplitRouting(enabled: Boolean) {
        viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(splitRouting = enabled)) }
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
            _downloading.value = _downloading.value + code
            _downloadStatus.value = "Загрузка $code..."
            routingRulesManager.downloadRuleList(code).fold(
                onSuccess = { size ->
                    _downloadStatus.value = "$code загружен (${size / 1024} КБ)"
                    refreshDownloadedRules()
                },
                onFailure = { e ->
                    _downloadStatus.value = "Ошибка загрузки $code: ${e.message}"
                },
            )
            _downloading.value = _downloading.value - code
        }
    }

    fun downloadAllSelected() {
        viewModelScope.launch {
            val codes = config.value.directCountries.ifEmpty { listOf("ru") }
            _downloading.value = codes.toSet()
            _downloadStatus.value = "Загрузка ${codes.joinToString(", ")}..."
            var ok = 0
            for (code in codes) {
                routingRulesManager.downloadRuleList(code).fold(
                    onSuccess = { ok++; refreshDownloadedRules() },
                    onFailure = {},
                )
                _downloading.value = _downloading.value - code
            }
            _downloadStatus.value = "Загружено $ok/${codes.size} списков"
        }
    }

    // ── Per-app ──────────────────────────────────────────────────────────────

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
            _installedApps.value = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                .map { info ->
                    AppInfo(
                        packageName = info.packageName,
                        label = pm.getApplicationLabel(info).toString(),
                        isSystem = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0,
                    )
                }
                .sortedWith(compareBy({ it.isSystem }, { it.label.lowercase() }))
        }
    }

    fun setPerAppMode(mode: String) {
        viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(perAppMode = mode)) }
    }

    fun togglePerApp(packageName: String) {
        viewModelScope.launch {
            val current = config.value.perAppList.toMutableList()
            if (packageName in current) current.remove(packageName) else current.add(packageName)
            preferencesStore.saveConfig(config.value.copy(perAppList = current))
        }
    }
}
