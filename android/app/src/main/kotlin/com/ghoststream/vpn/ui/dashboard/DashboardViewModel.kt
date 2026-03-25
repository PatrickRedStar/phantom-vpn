package com.ghoststream.vpn.ui.dashboard

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.data.VpnConfig
import com.ghoststream.vpn.data.VpnStats
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.service.VpnStateManager
import com.ghoststream.vpn.util.FormatUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
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
            caCertPath      = p?.caCertPath,
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
                        startStatsPolling(state.since)
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

    private fun startStatsPolling(since: Instant) {
        viewModelScope.launch {
            while (vpnState.value is VpnState.Connected) {
                try {
                    val json = GhostStreamVpnService.nativeGetStats() ?: "{}"
                    val obj = JSONObject(json)
                    val elapsed = Duration.between(since, Instant.now()).seconds
                    _stats.value = VpnStats(
                        bytesRx     = obj.optLong("bytes_rx"),
                        bytesTx     = obj.optLong("bytes_tx"),
                        pktsRx      = obj.optLong("pkts_rx"),
                        pktsTx      = obj.optLong("pkts_tx"),
                        connected   = obj.optBoolean("connected"),
                        elapsedSecs = elapsed,
                    )
                } catch (_: Exception) {}
                delay(1000)
            }
        }
    }

    private fun fetchSubscriptionInfo() {
        val profile = profilesStore.getActiveProfile() ?: return
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
                            _subscriptionText.value = formatExpiry(expiresAt)
                            profilesStore.updateProfile(
                                profile.copy(cachedExpiresAt = expiresAt, cachedEnabled = enabled),
                            )
                            break
                        }
                    }
                } else {
                    conn.disconnect()
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
        val cfg = config.value
        if (cfg.serverAddr.isBlank()) return

        val profile = profilesStore.getActiveProfile()
        if (profile != null) {
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

        _preflightWarning.value = null
        VpnStateManager.update(VpnState.Connecting)
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
            if (cfg.splitRouting && cfg.directCountries.isNotEmpty()) {
                val mergedPath = routingRulesManager.mergeSelectedLists(cfg.directCountries)
                putExtra(GhostStreamVpnService.EXTRA_DIRECT_CIDRS, mergedPath ?: "")
            }
            putExtra(GhostStreamVpnService.EXTRA_PER_APP_MODE, cfg.perAppMode)
            putExtra(GhostStreamVpnService.EXTRA_PER_APP_LIST, cfg.perAppList.joinToString(","))
            putExtra(GhostStreamVpnService.EXTRA_CA_CERT_PATH, cfg.caCertPath ?: "")
        }
        ctx.startForegroundService(intent)
    }

    fun stopVpn() {
        VpnStateManager.update(VpnState.Disconnecting)
        val ctx = getApplication<Application>()
        ctx.startService(Intent(ctx, GhostStreamVpnService::class.java).apply {
            action = GhostStreamVpnService.ACTION_STOP
        })
    }
}
