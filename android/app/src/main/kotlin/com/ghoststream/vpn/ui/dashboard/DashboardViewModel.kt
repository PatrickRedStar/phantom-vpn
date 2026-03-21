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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.Duration
import java.time.Instant

class DashboardViewModel(application: Application) : AndroidViewModel(application) {

    private val preferencesStore = PreferencesStore(application)
    private val profilesStore = ProfilesStore.getInstance(application)
    private val routingRulesManager = RoutingRulesManager(application)
    val vpnState = VpnStateManager.state

    // Combined: active profile (server/cert) + global prefs (DNS/routing/per-app)
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

    private val _timerText = MutableStateFlow("00:00:00")
    val timerText: StateFlow<String> = _timerText

    private val _stats = MutableStateFlow(VpnStats())
    val stats: StateFlow<VpnStats> = _stats

    init {
        viewModelScope.launch {
            vpnState.collect { state ->
                when (state) {
                    is VpnState.Connected -> {
                        startTimer(state.since)
                        startStatsPolling(state.since)
                    }
                    else -> {
                        _timerText.value = "00:00:00"
                        _stats.value = VpnStats()
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

    fun startVpn() {
        val cfg = config.value
        if (cfg.serverAddr.isBlank()) return
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
