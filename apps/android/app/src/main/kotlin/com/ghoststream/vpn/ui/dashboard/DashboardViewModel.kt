package com.ghoststream.vpn.ui.dashboard

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.AdminHttpClient
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.data.VpnConfig
import com.ghoststream.vpn.data.VpnStats
import okhttp3.Request
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.service.VpnStateManager
import com.ghoststream.vpn.service.StatusFrameData
import com.ghoststream.vpn.util.FormatUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.time.Duration
import java.time.Instant

class DashboardViewModel(application: Application) : AndroidViewModel(application) {

    private val preferencesStore = PreferencesStore(application)
    private val profilesStore = ProfilesStore.getInstance(application)
    private val routingRulesManager = RoutingRulesManager(application)
    val vpnState = VpnStateManager.state

    // Combined: active profile (server/cert + per-profile overrides) + global prefs fallback
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
            tunAddr         = p?.tunAddr ?: "10.7.0.2/24",
            dnsServers      = p?.dnsServers ?: prefs.dnsServers,
            splitRouting    = p?.splitRouting ?: prefs.splitRouting,
            directCountries = p?.directCountries ?: prefs.directCountries,
            perAppMode      = p?.perAppMode ?: prefs.perAppMode,
            perAppList      = p?.perAppList ?: prefs.perAppList,
        )
    }.stateIn(viewModelScope, SharingStarted.Eagerly, VpnConfig())

    private val _timerText = MutableStateFlow("00:00:00")
    val timerText: StateFlow<String> = _timerText

    /** Push-based status frame from Rust via VpnStateManager. */
    val statusFrame: StateFlow<StatusFrameData> = VpnStateManager.statusFrame

    private val _stats = MutableStateFlow(VpnStats())
    val stats: StateFlow<VpnStats> = _stats

    private val _subscriptionText = MutableStateFlow<String?>(null)
    val subscriptionText: StateFlow<String?> = _subscriptionText

    private val _preflightWarning = MutableStateFlow<String?>(null)
    val preflightWarning: StateFlow<String?> = _preflightWarning

    init {
        viewModelScope.launch {
            vpnState.collect { state ->
                when (state) {
                    is VpnState.Connected -> {
                        startTimer(state.since)
                        fetchSubscriptionInfo()
                    }
                    else -> {
                        _timerText.value = "00:00:00"
                        _stats.value = VpnStats()
                        _subscriptionText.value = null
                    }
                }
            }
        }
    }

    private fun startTimer(since: Instant) {
        viewModelScope.launch {
            while (vpnState.value is VpnState.Connected) {
                val elapsed = Duration.between(since, Instant.now()).seconds
                _timerText.value = FormatUtils.formatDuration(elapsed)
                delay(1000)
            }
        }
    }

    // Stats are now push-based via VpnStateManager.statusFrame (Phase 4).
    // The old nativeGetStats() polling was removed — it returned null after Phase 4.

    private fun fetchSubscriptionInfo() {
        val profile = profilesStore.getActiveProfile() ?: return
        val tunIp = profile.tunAddr.substringBefore('/')
        val parts = tunIp.split('.')
        val gateway = if (parts.size == 4) "${parts[0]}.${parts[1]}.${parts[2]}.1" else "10.7.0.1"
        val baseUrl = "https://$gateway:8080"

        viewModelScope.launch(Dispatchers.IO) {
            try {
                val outcome = AdminHttpClient.build(
                    certPemPath = profile.certPath,
                    keyPemPath = profile.keyPath,
                    pinnedFp = profile.cachedAdminServerCertFp,
                )
                val meReq = Request.Builder().url("$baseUrl/api/me").get().build()
                val meBody = outcome.client.newCall(meReq).execute().use {
                    if (!it.isSuccessful) return@launch
                    it.body?.string().orEmpty()
                }
                val me = JSONObject(meBody)
                val isAdmin = me.optBoolean("is_admin", false)

                val clReq = Request.Builder().url("$baseUrl/api/clients").get().build()
                val clBody = outcome.client.newCall(clReq).execute().use {
                    if (!it.isSuccessful) return@launch
                    it.body?.string().orEmpty()
                }
                val arr = JSONArray(clBody)
                for (i in 0 until arr.length()) {
                    val o = arr.getJSONObject(i)
                    if (o.optString("tun_addr").substringBefore('/') == tunIp) {
                        val expiresAt = o.optLong("expires_at", 0).takeIf { it > 0 }
                        val enabled = o.optBoolean("enabled", true)
                        _subscriptionText.value = formatExpiry(expiresAt)
                        profilesStore.updateProfile(
                            profile.copy(
                                cachedExpiresAt = expiresAt,
                                cachedEnabled = enabled,
                                cachedIsAdmin = isAdmin,
                                cachedAdminServerCertFp = outcome.serverCertFpRef.value
                                    ?: profile.cachedAdminServerCertFp,
                            ),
                        )
                        break
                    }
                }
            } catch (_: Exception) {}
        }
    }

    private fun formatExpiry(expiresAt: Long?): String {
        if (expiresAt == null) return "Подписка: бессрочно"
        val remaining = expiresAt - (System.currentTimeMillis() / 1000)
        return if (remaining > 0) {
            val days = remaining / 86400
            val hours = (remaining % 86400) / 3600
            when {
                days > 1  -> "Подписка: ${days}д ${hours}ч"
                days == 1L -> "Подписка: 1д ${hours}ч"
                hours > 0 -> "Подписка: ${hours}ч"
                else      -> "Подписка: < 1ч ⚠"
            }
        } else {
            "Подписка истекла ⚠"
        }
    }

    fun dismissPreflightWarning() { _preflightWarning.value = null }

    fun startVpn() {
        var cfg = config.value
        if (cfg.serverAddr.isBlank()) return

        var profile = profilesStore.getActiveProfile()
        if (profile != null) {
            // Restore cert files from inline PEM if they were deleted (e.g. app update)
            val certExists = java.io.File(profile.certPath).exists()
            val keyExists = java.io.File(profile.keyPath).exists()
            if (!certExists || !keyExists) {
                val restored = profilesStore.ensureCertFiles(profile)
                if (restored == null) {
                    _preflightWarning.value = "Сертификаты профиля утеряны. Импортируйте строку подключения заново."
                    VpnStateManager.update(VpnState.Error("Сертификаты не найдены"))
                    return
                }
                profile = restored
                cfg = cfg.copy(certPath = restored.certPath, keyPath = restored.keyPath)
            }
            val cachedExp = profile.cachedExpiresAt
            if (cachedExp != null && cachedExp > 0) {
                val remaining = cachedExp - (System.currentTimeMillis() / 1000)
                if (remaining <= 0) {
                    _preflightWarning.value = "Подписка истекла. Обновите подписку у администратора."
                    VpnStateManager.update(VpnState.Error("Подписка истекла"))
                    return
                }
            }
            if (profile.cachedEnabled == false) {
                _preflightWarning.value = "Клиент отключён администратором."
                VpnStateManager.update(VpnState.Error("Клиент отключён"))
                return
            }
        }

        viewModelScope.launch {
            _preflightWarning.value = null
            VpnStateManager.update(VpnState.Connecting)
            val directCidrsPath = if (cfg.splitRouting && cfg.directCountries.isNotEmpty()) {
                val missing = withContext(Dispatchers.IO) {
                    routingRulesManager.missingSelectedLists(cfg.directCountries)
                }
                if (missing.isNotEmpty()) {
                    _preflightWarning.value =
                        "Не загружены списки: ${missing.joinToString(", ")}. Загрузите их в Настройках."
                    VpnStateManager.update(VpnState.Error("Списки маршрутов не загружены"))
                    return@launch
                } else {
                    withContext(Dispatchers.IO) {
                        routingRulesManager.mergeSelectedLists(cfg.directCountries) ?: ""
                    }
                }
            } else {
                ""
            }

            // Build ghs:// conn_string required by Phase 4 nativeStart
            val connString = if (profile != null) {
                withContext(Dispatchers.IO) { ConnStringParser.build(profile!!) ?: "" }
            } else ""

            val ctx = getApplication<Application>()
            val intent = Intent(ctx, GhostStreamVpnService::class.java).apply {
                action = GhostStreamVpnService.ACTION_START
                putExtra(GhostStreamVpnService.EXTRA_SERVER_ADDR, cfg.serverAddr)
                putExtra(GhostStreamVpnService.EXTRA_SERVER_NAME,
                    cfg.serverName.ifBlank { cfg.serverAddr.substringBefore(":") })
                putExtra(GhostStreamVpnService.EXTRA_INSECURE, cfg.insecure)
                putExtra(GhostStreamVpnService.EXTRA_CERT_PATH, cfg.certPath)
                putExtra(GhostStreamVpnService.EXTRA_KEY_PATH, cfg.keyPath)
                putExtra(GhostStreamVpnService.EXTRA_TUN_ADDR, cfg.tunAddr)
                putExtra(GhostStreamVpnService.EXTRA_DNS_SERVERS, cfg.dnsServers.joinToString(","))
                putExtra(GhostStreamVpnService.EXTRA_SPLIT_ROUTING, cfg.splitRouting)
                putExtra(GhostStreamVpnService.EXTRA_DIRECT_CIDRS, directCidrsPath)
                putExtra(GhostStreamVpnService.EXTRA_PER_APP_MODE, cfg.perAppMode)
                putExtra(GhostStreamVpnService.EXTRA_PER_APP_LIST, cfg.perAppList.joinToString(","))
                putExtra(GhostStreamVpnService.EXTRA_CONN_STRING, connString)
                if (profile?.relayEnabled == true && !profile.relayAddr.isNullOrBlank()) {
                    putExtra(GhostStreamVpnService.EXTRA_RELAY_ADDR, profile.relayAddr)
                }
            }
            ctx.startForegroundService(intent)
        }
    }

    fun stopVpn() {
        VpnStateManager.update(VpnState.Disconnecting)
        val ctx = getApplication<Application>()
        ctx.startService(Intent(ctx, GhostStreamVpnService::class.java).apply {
            action = GhostStreamVpnService.ACTION_STOP
        })
    }
}
