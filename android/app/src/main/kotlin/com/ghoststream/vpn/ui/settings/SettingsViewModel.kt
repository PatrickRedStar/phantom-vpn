package com.ghoststream.vpn.ui.settings

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PairingClient
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.data.VpnConfig
import com.ghoststream.vpn.data.VpnProfile
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.VpnStateManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URL

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val preferencesStore = PreferencesStore(application)
    val profilesStore = ProfilesStore.getInstance(application)
    val routingRulesManager = RoutingRulesManager(application)

    val profiles: StateFlow<List<VpnProfile>> = profilesStore.profiles
    val activeProfileId: StateFlow<String?> = profilesStore.activeId

    // Combined config: profile overrides first, global prefs as fallback
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
            dnsServers      = p?.dnsServers ?: prefs.dnsServers,
            splitRouting    = p?.splitRouting ?: prefs.splitRouting,
            directCountries = p?.directCountries ?: prefs.directCountries,
            perAppMode      = p?.perAppMode ?: prefs.perAppMode,
            perAppList      = p?.perAppList ?: prefs.perAppList,
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
                        adminUrl   = parsed.adminUrl,
                        adminToken = parsed.adminToken,
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
        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
            profilesStore.updateProfile(profile.copy(dnsServers = servers))
        } else {
            viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(dnsServers = servers)) }
        }
    }

    // ── Routing ──────────────────────────────────────────────────────────────

    private val _downloadedRules = MutableStateFlow<Map<String, RoutingRulesManager.RuleInfo>>(emptyMap())
    val downloadedRules: StateFlow<Map<String, RoutingRulesManager.RuleInfo>> = _downloadedRules

    private val _downloading = MutableStateFlow<Set<String>>(emptySet())
    val downloading: StateFlow<Set<String>> = _downloading

    private val _downloadStatus = MutableStateFlow("")
    val downloadStatus: StateFlow<String> = _downloadStatus

    // ── Ping ─────────────────────────────────────────────────────────────────

    private val _pingResults = MutableStateFlow<Map<String, Long?>>(emptyMap())
    val pingResults: StateFlow<Map<String, Long?>> = _pingResults

    private val _pinging = MutableStateFlow<Set<String>>(emptySet())
    val pinging: StateFlow<Set<String>> = _pinging

    fun pingProfile(id: String) {
        val profile = profiles.value.find { it.id == id } ?: return
        if (id in _pinging.value) return
        viewModelScope.launch {
            _pinging.value = _pinging.value + id
            val latency = measureTcpLatency(profile.serverAddr)
            _pingResults.value = _pingResults.value + (id to latency)
            _pinging.value = _pinging.value - id
        }
    }

    fun pingAll() = profiles.value.forEach { pingProfile(it.id) }

    private suspend fun measureTcpLatency(serverAddr: String): Long? = withContext(Dispatchers.IO) {
        try {
            val lastColon = serverAddr.lastIndexOf(':')
            val host = if (lastColon > 0) serverAddr.substring(0, lastColon) else serverAddr
            val port = if (lastColon > 0) serverAddr.substring(lastColon + 1).toIntOrNull() ?: 8443 else 8443
            val start = System.currentTimeMillis()
            Socket().use { it.connect(InetSocketAddress(host, port), 3000) }
            System.currentTimeMillis() - start
        } catch (_: Exception) { null }
    }

    // ── Subscription info ─────────────────────────────────────────────────────

    private val _profileSubscriptions = MutableStateFlow<Map<String, String>>(emptyMap())
    val profileSubscriptions: StateFlow<Map<String, String>> = _profileSubscriptions

    private fun fetchAllSubscriptions() {
        profiles.value
            .filter { it.adminUrl != null && it.adminToken != null }
            .forEach { fetchProfileSubscription(it) }
    }

    private fun fetchProfileSubscription(profile: VpnProfile) {
        val adminUrl = profile.adminUrl ?: return
        val adminToken = profile.adminToken ?: return
        val myTunIp = profile.tunAddr.substringBefore('/')

        viewModelScope.launch(Dispatchers.IO) {
            try {
                val url = URL("${adminUrl.trimEnd('/')}/api/clients")
                val conn = url.openConnection() as HttpURLConnection
                conn.setRequestProperty("Authorization", "Bearer $adminToken")
                conn.connectTimeout = 5000
                conn.readTimeout = 10000
                if (conn.responseCode == 200) {
                    val body = conn.inputStream.bufferedReader().readText()
                    conn.disconnect()
                    val arr = JSONArray(body)
                    for (i in 0 until arr.length()) {
                        val o = arr.getJSONObject(i)
                        if (o.optString("tun_addr").substringBefore('/') == myTunIp) {
                            val expiresAt = o.optLong("expires_at", 0).takeIf { it > 0 }
                            val enabled = o.optBoolean("enabled", true)
                            val text = if (expiresAt == null) {
                                "бессрочно"
                            } else {
                                val rem = expiresAt - (System.currentTimeMillis() / 1000)
                                if (rem > 0) {
                                    val d = rem / 86400
                                    val h = (rem % 86400) / 3600
                                    when {
                                        d > 0 -> "${d}д"
                                        h > 0 -> "${h}ч"
                                        else  -> "< 1ч ⚠"
                                    }
                                } else "истекла ⚠"
                            }
                            _profileSubscriptions.value = _profileSubscriptions.value + (profile.id to text)
                            profilesStore.updateProfile(
                                profile.copy(cachedExpiresAt = expiresAt, cachedEnabled = enabled),
                            )
                            break
                        }
                    }
                } else conn.disconnect()
            } catch (_: Exception) {}
        }
    }

    // ── Share to TV ──────────────────────────────────────────────────────────

    private val _sendToTvStatus = MutableStateFlow<String?>(null)
    val sendToTvStatus: StateFlow<String?> = _sendToTvStatus

    fun sendToTv(profileId: String, pairingQrText: String) {
        val profile = profiles.value.find { it.id == profileId } ?: return
        val connString = ConnStringParser.build(profile) ?: run {
            _sendToTvStatus.value = "Ошибка: не удалось собрать строку подключения"
            return
        }
        val payload = PairingClient.parsePairingQr(pairingQrText) ?: run {
            _sendToTvStatus.value = "Ошибка: не распознан QR-код TV"
            return
        }
        viewModelScope.launch {
            _sendToTvStatus.value = "Отправка..."
            PairingClient.send(payload, connString).fold(
                onSuccess = { _sendToTvStatus.value = "Отправлено на TV!" },
                onFailure = { _sendToTvStatus.value = "Ошибка: ${it.message}" },
            )
        }
    }

    fun clearSendToTvStatus() { _sendToTvStatus.value = null }

    // ── Debug report ──────────────────────────────────────────────────────────

    fun shareDebugReport(context: Context) {
        viewModelScope.launch {
            val sb = StringBuilder()
            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.getDefault())
            sb.appendLine("=== GhostStream VPN Debug Report ===")
            sb.appendLine("Дата: ${sdf.format(java.util.Date())}")
            sb.appendLine()
            sb.appendLine("--- Приложение ---")
            sb.appendLine("Версия: ${com.ghoststream.vpn.BuildConfig.VERSION_NAME} (${com.ghoststream.vpn.BuildConfig.VERSION_CODE})")
            sb.appendLine("Git tag: ${com.ghoststream.vpn.BuildConfig.GIT_TAG}")
            sb.appendLine()
            sb.appendLine("--- Устройство ---")
            sb.appendLine("Android: ${android.os.Build.VERSION.RELEASE} (SDK ${android.os.Build.VERSION.SDK_INT})")
            sb.appendLine("Устройство: ${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
            sb.appendLine("ABI: ${android.os.Build.SUPPORTED_ABIS.joinToString()}")
            sb.appendLine()
            sb.appendLine("--- Активный профиль ---")
            val activeProfile = profilesStore.getActiveProfile()
            if (activeProfile != null) {
                sb.appendLine("Имя: ${activeProfile.name}")
                sb.appendLine("Сервер: ${activeProfile.serverAddr}")
                sb.appendLine("SNI: ${activeProfile.serverName}")
                sb.appendLine("Insecure: ${activeProfile.insecure}")
                sb.appendLine("TUN: ${activeProfile.tunAddr}")
                sb.appendLine("CA cert: ${if (activeProfile.caCertPath != null) "есть" else "нет"}")
                sb.appendLine("Admin URL: ${if (activeProfile.adminUrl != null) "настроен" else "нет"}")
            } else {
                sb.appendLine("Нет активного профиля")
            }
            sb.appendLine()
            sb.appendLine("--- Конфигурация ---")
            val cfg = config.value
            sb.appendLine("DNS: ${cfg.dnsServers.joinToString()}")
            sb.appendLine("Раздельная маршрутизация: ${cfg.splitRouting}")
            if (cfg.splitRouting) sb.appendLine("Прямые страны: ${cfg.directCountries.joinToString()}")
            sb.appendLine("Per-app режим: ${cfg.perAppMode}")
            if (cfg.perAppMode != "none") sb.appendLine("Приложений выбрано: ${cfg.perAppList.size}")
            sb.appendLine()
            sb.appendLine("--- Состояние VPN ---")
            sb.appendLine("Состояние: ${VpnStateManager.state.value}")
            sb.appendLine()
            sb.appendLine("--- Логи (последние 500 строк) ---")
            try {
                val json = GhostStreamVpnService.nativeGetLogs(-1L)
                if (json != null && json != "[]") {
                    val arr = JSONArray(json)
                    val start = maxOf(0, arr.length() - 500)
                    for (i in start until arr.length()) {
                        val o = arr.getJSONObject(i)
                        sb.appendLine("${o.optString("ts")} [${o.optString("level")}] ${o.optString("msg")}")
                    }
                } else {
                    sb.appendLine("Логи пусты")
                }
            } catch (e: Exception) {
                sb.appendLine("Ошибка получения логов: ${e.message}")
            }

            val dir = File(context.cacheDir, "debug")
            dir.mkdirs()
            val file = File(dir, "ghoststream-debug.txt")
            file.writeText(sb.toString())
            val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_SUBJECT, "GhostStream VPN Debug Report")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "Поделиться отладочной информацией"))
        }
    }

    init {
        refreshDownloadedRules()
        migrateLegacyIfNeeded()
        fetchAllSubscriptions()
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
        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
            profilesStore.updateProfile(profile.copy(splitRouting = enabled))
        } else {
            viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(splitRouting = enabled)) }
        }
    }

    fun toggleDirectCountry(code: String) {
        val current = config.value.directCountries.toMutableList()
        if (code in current) current.remove(code) else current.add(code)
        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
            profilesStore.updateProfile(profile.copy(directCountries = current))
        } else {
            viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(directCountries = current)) }
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
        // true only for pure system apps never updated by user (background daemons, etc.)
        // Pre-installed apps that have been updated (Chrome, YouTube, etc.) are NOT isSystem
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
                    val isSystemPartition = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                    val isUpdated = (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
                    AppInfo(
                        packageName = info.packageName,
                        label = pm.getApplicationLabel(info).toString(),
                        // Pure system partition app (never updated) — hide from picker
                        isSystem = isSystemPartition && !isUpdated,
                    )
                }
                .sortedWith(compareBy({ it.isSystem }, { it.label.lowercase() }))
        }
    }

    fun setPerAppMode(mode: String) {
        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
            profilesStore.updateProfile(profile.copy(perAppMode = mode))
        } else {
            viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(perAppMode = mode)) }
        }
    }

    fun togglePerApp(packageName: String) {
        val current = config.value.perAppList.toMutableList()
        if (packageName in current) current.remove(packageName) else current.add(packageName)
        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
            profilesStore.updateProfile(profile.copy(perAppList = current))
        } else {
            viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(perAppList = current)) }
        }
    }
}
