package com.ghoststream.vpn.ui.settings

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.ConnStringParser
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
import java.io.File
import java.io.ByteArrayInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate

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
            certPath        = p?.certPath ?: "",
            keyPath         = p?.keyPath ?: "",
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

    val languageOverride: StateFlow<String?> = preferencesStore.languageOverride
        .stateIn(viewModelScope, SharingStarted.Eagerly, null)

    fun setLanguageOverride(code: String?) {
        viewModelScope.launch { preferencesStore.setLanguageOverride(code) }
    }

    val appIcon: StateFlow<String> = preferencesStore.appIcon
        .stateIn(viewModelScope, SharingStarted.Eagerly, "bone")

    fun setAppIcon(icon: String) {
        viewModelScope.launch {
            preferencesStore.setAppIcon(icon)
            switchLauncherIcon(icon)
        }
    }

    private fun switchLauncherIcon(icon: String) {
        val ctx = getApplication<Application>()
        val pm = ctx.packageManager
        val pkg = ctx.packageName

        // alias-классы живут в namespace (com.ghoststream.vpn), не в applicationId
        val classNs = com.ghoststream.vpn.BuildConfig::class.java.`package`!!.name
        val boneAlias = android.content.ComponentName(pkg, "$classNs.IconBone")
        val scopeAlias = android.content.ComponentName(pkg, "$classNs.IconScope")

        val (enable, disable) = when (icon) {
            "scope" -> scopeAlias to boneAlias
            else -> boneAlias to scopeAlias
        }

        pm.setComponentEnabledSetting(
            enable,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        pm.setComponentEnabledSetting(
            disable,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
    }

    val autoStartOnBoot: StateFlow<Boolean> = preferencesStore.autoStartOnBoot
        .stateIn(viewModelScope, SharingStarted.Eagerly, false)

    fun setAutoStartOnBoot(enabled: Boolean) {
        viewModelScope.launch { preferencesStore.setAutoStartOnBoot(enabled) }
    }

    // ── v0.25.1 W3-12: OEM autostart settings ─────────────────────────────
    //
    // On Xiaomi/MIUI, Huawei/EMUI, Vivo/FuntouchOS, Oppo/ColorOS, Realme
    // and Honor the "Autostart" / "Background startup" permission is *separate*
    // from Android's standard battery whitelist. Without it, BOOT_COMPLETED
    // is silently dropped → BootReceiver never fires → user thinks "VPN
    // doesn't start in the morning, app is broken". We can't grant it
    // ourselves; we can only deep-link into the right OEM activity.
    //
    // If the deep link fails (vendor removed the activity in newer ROM,
    // device is rooted custom ROM, etc.) we fall back to standard app
    // details so the user can at least navigate from there.
    fun openOemAutostartSettings(context: Context) {
        val manufacturer = android.os.Build.MANUFACTURER.lowercase()
        val intent = Intent().apply {
            when (manufacturer) {
                "xiaomi", "redmi" -> {
                    component = android.content.ComponentName(
                        "com.miui.securitycenter",
                        "com.miui.permcenter.autostart.AutoStartManagementActivity",
                    )
                }
                "huawei", "honor" -> {
                    component = android.content.ComponentName(
                        "com.huawei.systemmanager",
                        "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                    )
                }
                "vivo" -> {
                    component = android.content.ComponentName(
                        "com.vivo.permissionmanager",
                        "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                    )
                }
                "oppo", "realme" -> {
                    component = android.content.ComponentName(
                        "com.coloros.safecenter",
                        "com.coloros.safecenter.permission.startup.StartupAppListActivity",
                    )
                }
                else -> {
                    // Fallback: per-app details — at least lets user find
                    // "Autostart" toggle on stock-ish ROMs that put it there.
                    action = android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    data = android.net.Uri.parse("package:${context.packageName}")
                }
            }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            // Component name moved / removed in newer ROM build → fall back
            // to the universal app-details screen so the user isn't stuck.
            val fallback = Intent(
                android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.parse("package:${context.packageName}"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try { context.startActivity(fallback) } catch (_: Exception) {}
        }
    }

    // ── v0.25.1 W3-13: battery optimisation ──────────────────────────────
    //
    // MIUI/EMUI/OxygenOS kill the foreground service after ~30 min screen-off
    // unless the app is exempt. A direct per-app request
    // (REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) is a Play-policy risk, so we only
    // open the system list and let the user flip it there.
    fun openBatteryOptimisationSettings(context: Context) {
        val intent = Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }.onFailure {
            runCatching {
                context.startActivity(
                    Intent(android.provider.Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }
        }
    }

    /** System VPN settings — the only place to turn on Always-on VPN / lockdown. */
    fun openSystemVpnSettings(context: Context) {
        val intent = Intent(android.provider.Settings.ACTION_VPN_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }
    }

    // ── Import dialog state ───────────────────────────────────────────────────

    private val _pendingConnString = MutableStateFlow("")
    val pendingConnString: StateFlow<String> = _pendingConnString

    private val _pendingName = MutableStateFlow("")
    val pendingName: StateFlow<String> = _pendingName

    private val _importStatus = MutableStateFlow("")
    val importStatus: StateFlow<String> = _importStatus

    fun setPendingConnString(value: String) {
        _pendingConnString.value = value
        _importStatus.value = ""
    }
    fun setPendingName(value: String)       { _pendingName.value = value }

    /** Imports the pending string; false keeps the dialog open with [importStatus]. */
    fun importConfig(): Boolean {
        val input = _pendingConnString.value.trim()
        if (input.isEmpty()) {
            _importStatus.value = getApplication<Application>().getString(R.string.import_empty)
            return false
        }

        return ConnStringParser.parse(input).fold(
            onSuccess = { parsed ->
                val ctx = getApplication<Application>()
                val id = java.util.UUID.randomUUID().toString()
                val profileDir = File(ctx.filesDir, "profiles/$id").also { it.mkdirs() }

                val certFile = File(profileDir, "client.crt")
                val keyFile  = File(profileDir, "client.key")
                certFile.writeText(parsed.cert)
                keyFile.writeText(parsed.key)

                val name = _pendingName.value.trim().ifEmpty {
                    extractClientNameFromCert(parsed.cert)
                        ?: parsed.sni.substringBefore(".").replaceFirstChar { it.uppercase() }
                            .ifEmpty { "Подключение" }
                }

                profilesStore.addProfile(
                    VpnProfile(
                        id         = id,
                        name       = name,
                        serverAddr = parsed.addr,
                        serverName = parsed.sni,
                        certPath   = certFile.absolutePath,
                        keyPath    = keyFile.absolutePath,
                        certPem    = parsed.cert,
                        keyPem     = parsed.key,
                        tunAddr    = parsed.tun,
                    ),
                )

                _pendingConnString.value = ""
                _pendingName.value = ""
                _importStatus.value = ""
                true
            },
            onFailure = {
                _importStatus.value = getApplication<Application>()
                    .getString(R.string.import_failed, it.message ?: "")
                false
            },
        )
    }

    fun clearImportStatus() { _importStatus.value = "" }

    fun deleteProfile(id: String) = profilesStore.deleteProfile(id)

    fun setActiveProfile(id: String) = profilesStore.setActiveId(id)

    fun renameProfile(id: String, name: String) {
        val profile = profilesStore.profiles.value.find { it.id == id } ?: return
        profilesStore.updateProfile(profile.copy(name = name.trim().ifEmpty { profile.name }))
    }

    fun updateProfileFields(
        id: String,
        name: String,
        relayEnabled: Boolean,
        relayAddr: String?,
    ) {
        val profile = profilesStore.profiles.value.find { it.id == id } ?: return
        // SNI is not editable: the server certificate is always verified
        // against it, so any other value just breaks the connection.
        profilesStore.updateProfile(
            profile.copy(
                name = name.trim().ifEmpty { profile.name },
                relayEnabled = relayEnabled,
                relayAddr = relayAddr,
            ),
        )
    }

    fun updateProfileEndpoint(id: String, serverAddr: String, serverName: String) {
        val profile = profilesStore.profiles.value.find { it.id == id } ?: return
        val addr = serverAddr.trim()
        val sni = serverName.trim()
        if (addr.isEmpty() || sni.isEmpty()) return
        profilesStore.updateProfile(profile.copy(serverAddr = addr, serverName = sni))
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

    /** Saves a typed DNS list; false (nothing saved) when it is empty or has a non-IPv4 entry. */
    fun setDnsServersFromText(text: String): Boolean {
        val servers = parseDnsList(text) ?: return false
        setDnsServers(servers)
        return true
    }

    companion object {
        /** "1.1.1.1, 8.8.8.8; 9.9.9.9" → list; null when empty or any entry is not IPv4. */
        fun parseDnsList(text: String): List<String>? {
            val tokens = text.split(',', ';', ' ', '\n', '\t').filter { it.isNotBlank() }
            if (tokens.isEmpty() || !tokens.all(::isIpv4)) return null
            return tokens.distinct()
        }

        private fun isIpv4(s: String): Boolean {
            val parts = s.split('.')
            return parts.size == 4 && parts.all { p ->
                p.length in 1..3 && p.all(Char::isDigit) && p.toInt() <= 255
            }
        }
    }

    // ── Routing ──────────────────────────────────────────────────────────────

    private val _downloadedRules = MutableStateFlow<Map<String, RoutingRulesManager.RuleInfo>>(emptyMap())
    val downloadedRules: StateFlow<Map<String, RoutingRulesManager.RuleInfo>> = _downloadedRules

    private val _downloading = MutableStateFlow<Set<String>>(emptySet())
    val downloading: StateFlow<Set<String>> = _downloading

    private val _downloadStatus = MutableStateFlow("")
    val downloadStatus: StateFlow<String> = _downloadStatus
    private val _rulePreviewCode = MutableStateFlow<String?>(null)
    val rulePreviewCode: StateFlow<String?> = _rulePreviewCode
    private val _rulePreviewLines = MutableStateFlow<List<String>>(emptyList())
    val rulePreviewLines: StateFlow<List<String>> = _rulePreviewLines

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
            // With the relay on, the client never dials the exit directly.
            val target = profile.relayAddr?.takeIf { profile.relayEnabled && it.isNotBlank() }
                ?: profile.serverAddr
            val latency = measureTcpLatency(target)
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

    private fun extractClientNameFromCert(certPem: String): String? = runCatching {
        val certFactory = CertificateFactory.getInstance("X.509")
        val cert = certFactory.generateCertificate(
            ByteArrayInputStream(certPem.toByteArray(Charsets.UTF_8)),
        ) as X509Certificate
        val subjectDn = cert.subjectX500Principal.name
        val cn = Regex("""(?:^|,)\s*CN=([^,]+)""")
            .find(subjectDn)
            ?.groupValues
            ?.getOrNull(1)
            ?.trim()
            ?.takeIf { it.isNotBlank() }
        cn
    }.getOrNull()

    // ── Debug report ──────────────────────────────────────────────────────────

    fun shareDebugReport(context: Context) {
        viewModelScope.launch {
            runCatching {
                val uri = withContext(Dispatchers.IO) {
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
                        sb.appendLine("TUN: ${activeProfile.tunAddr}")
                        sb.appendLine("Admin: ${if (activeProfile.cachedIsAdmin == true) "да" else "нет"}")
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

                    // v0.26.21: диагностический маркер. persist=N — реальный размер
                    // файла LogPersister'а на диске; tail=K — сколько строк отдал
                    // tailLines(2000). Если N>0 и K=0 → баг в tailLines. Если N=0 →
                    // LogPersister не пишет, копаем producer.
                    val logFile = java.io.File(context.filesDir, "logs/ghoststream.log")
                    val persistBytes = if (logFile.exists()) logFile.length() else -1L

                    com.ghoststream.vpn.service.LogPersister.flushPending()
                    val lines = com.ghoststream.vpn.service.LogPersister.tailLines(context, 2000)
                    sb.appendLine("--- Логи (persist=${persistBytes}B, tail=${lines.size} строк) ---")
                    if (lines.isEmpty()) {
                        sb.appendLine("Логи пусты — запустите туннель чтобы накопить.")
                    } else {
                        lines.forEach { sb.appendLine(it) }
                    }

                    val dir = File(context.cacheDir, "debug")
                    dir.mkdirs()
                    val file = File(dir, "ghoststream-debug.txt")
                    file.writeText(sb.toString())
                    FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
                }
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    putExtra(Intent.EXTRA_SUBJECT, "GhostStream VPN Debug Report")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                context.startActivity(Intent.createChooser(intent, "Поделиться отладочной информацией"))
            }.onFailure { e ->
                android.util.Log.e("SettingsViewModel", "shareDebugReport failed", e)
                android.widget.Toast.makeText(
                    context,
                    "Не удалось собрать отчёт: ${e.message}",
                    android.widget.Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    init {
        refreshDownloadedRules()
        migrateLegacyIfNeeded()
        // Subscription / admin flag come from /api/me, asked by DashboardViewModel
        // once per session through the live tunnel; here we only render the cache.
    }

    private fun migrateLegacyIfNeeded() {
        if (profilesStore.profiles.value.isNotEmpty()) return
        viewModelScope.launch {
            val old = preferencesStore.config.first()
            profilesStore.migrateFromLegacy(
                serverAddr = old.serverAddr,
                serverName = old.serverName,
                certPath   = old.certPath,
                keyPath    = old.keyPath,
                tunAddr    = old.tunAddr,
            )
        }
    }

    private fun refreshDownloadedRules() {
        _downloadedRules.value = routingRulesManager.getDownloadedRules().associateBy { it.code }
    }

    fun setSplitRouting(enabled: Boolean) {
        // Включённый split без единой страны — тихий полный туннель. Дефолт: RU.
        // Обе правки одной записью: два асинхронных saveConfig гоняются и затирают друг друга.
        val addRu = enabled && config.value.directCountries.isEmpty()
        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
            profilesStore.updateProfile(profile.copy(
                splitRouting = enabled,
                directCountries = if (addRu) listOf("ru") else profile.directCountries,
            ))
        } else {
            viewModelScope.launch {
                preferencesStore.saveConfig(config.value.copy(
                    splitRouting = enabled,
                    directCountries = if (addRu) listOf("ru") else config.value.directCountries,
                ))
            }
        }
        if (addRu && !routingRulesManager.isDownloaded("ru")) {
            downloadCountryRules("ru")
        }
    }

    fun toggleDirectCountry(code: String) {
        val current = config.value.directCountries.toMutableList()
        val added = code !in current
        if (added) current.add(code) else current.remove(code)
        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
            profilesStore.updateProfile(profile.copy(directCountries = current))
        } else {
            viewModelScope.launch { preferencesStore.saveConfig(config.value.copy(directCountries = current)) }
        }
        if (added && !routingRulesManager.isDownloaded(code)) {
            downloadCountryRules(code)
        }
    }

    fun downloadCountryRules(code: String) {
        viewModelScope.launch {
            _downloading.value = _downloading.value + code
            _downloadStatus.value = "Загрузка $code..."
            try {
                routingRulesManager.downloadRuleList(code).fold(
                    onSuccess = { size ->
                        _downloadStatus.value = "$code загружен (${size / 1024} КБ)"
                        refreshDownloadedRules()
                    },
                    onFailure = { e ->
                        _downloadStatus.value = "Ошибка загрузки $code: ${e.message}"
                    },
                )
            } finally {
                _downloading.value = _downloading.value - code
            }
        }
    }

    fun downloadAllSelected() {
        viewModelScope.launch {
            val codes = config.value.directCountries.ifEmpty { listOf("ru") }
            _downloading.value = codes.toSet()
            _downloadStatus.value = "Загрузка ${codes.joinToString(", ")}..."
            var ok = 0
            try {
                for (code in codes) {
                    routingRulesManager.downloadRuleList(code).fold(
                        onSuccess = { ok++; refreshDownloadedRules() },
                        onFailure = {},
                    )
                    _downloading.value = _downloading.value - code
                }
            } finally {
                _downloading.value = emptySet()
            }
            _downloadStatus.value = "Загружено $ok/${codes.size} списков"
        }
    }

    fun openRulePreview(code: String) {
        _rulePreviewCode.value = code
        _rulePreviewLines.value = routingRulesManager.previewRuleList(code)
    }

    fun closeRulePreview() {
        _rulePreviewCode.value = null
        _rulePreviewLines.value = emptyList()
    }

    fun ruleSourceUrl(code: String): String = routingRulesManager.sourceUrl(code)

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
    init { loadInstalledApps() }

    fun loadInstalledApps() {
        if (_installedApps.value.isNotEmpty()) return
        viewModelScope.launch {
            _installedApps.value = withContext(Dispatchers.IO) {
                val pm = getApplication<Application>().packageManager
                pm.getInstalledApplications(0)
                    .mapNotNull { info ->
                        val isSystemPartition = (info.flags and ApplicationInfo.FLAG_SYSTEM) != 0
                        val isUpdated = (info.flags and ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
                        // Skip pure system daemons early — no label lookup needed
                        if (isSystemPartition && !isUpdated) return@mapNotNull null
                        AppInfo(
                            packageName = info.packageName,
                            label = pm.getApplicationLabel(info).toString(),
                            isSystem = false,
                        )
                    }
                    .sortedBy { it.label.lowercase() }
            }
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
