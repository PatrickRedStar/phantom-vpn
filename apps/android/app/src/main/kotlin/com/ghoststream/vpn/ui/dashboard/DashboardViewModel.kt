package com.ghoststream.vpn.ui.dashboard

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.AdminHttpClient
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.data.VpnConfig
import com.ghoststream.vpn.data.VpnProfile
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.service.VpnStateManager
import com.ghoststream.vpn.service.StatusFrameData
import com.ghoststream.vpn.util.FormatUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.time.Duration
import java.time.Instant

class DashboardViewModel(application: Application) : AndroidViewModel(application) {

    private val preferencesStore = PreferencesStore(application)
    private val profilesStore = ProfilesStore.getInstance(application)
    private val routingRulesManager = RoutingRulesManager(application)
    /**
     * Honest VPN state derived from (lifecycle, StatusFrame.health).
     * v0.24.0: switched from raw `VpnStateManager.state` to
     * `derivedVpnState` so the dashboard never shows "Connected" while
     * the runtime knows the tunnel is silently dead (Stale/Throttled/
     * Reconnecting).
     */
    val vpnState = VpnStateManager.derivedVpnState

    /** Global prefs — fallback for what the profile doesn't override. Null until loaded. */
    private val prefs: StateFlow<VpnConfig?> =
        preferencesStore.config.stateIn(viewModelScope, SharingStarted.Eagerly, null)

    // Active profile (server/cert + per-profile overrides) + global prefs fallback
    private fun configOf(p: VpnProfile?, prefs: VpnConfig) = VpnConfig(
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

    private val _timerText = MutableStateFlow("00:00:00")
    val timerText: StateFlow<String> = _timerText

    /** Push-based status frame from Rust via VpnStateManager. */
    val statusFrame: StateFlow<StatusFrameData> = VpnStateManager.statusFrame

    private val _preflightWarning = MutableStateFlow<String?>(null)
    val preflightWarning: StateFlow<String?> = _preflightWarning

    /** Preflight of the current start, until the Intent is handed to the service. */
    private var startJob: Job? = null

    init {
        viewModelScope.launch {
            // Status frames arrive several times a second and Stale/Throttled
            // carry changing counters, so react only to a new session start:
            // collectLatest cancels the previous ticker by itself and /api/me
            // is asked once per session. Timer stays live across Connected/
            // Stale/Throttled — same session, context beats a reset.
            vpnState.map { sinceOf(it) }.distinctUntilChanged().collectLatest { since ->
                if (since == null) {
                    _timerText.value = "00:00:00"
                    return@collectLatest
                }
                launch(Dispatchers.IO) {
                    val id = profilesStore.getActiveProfile()?.id ?: return@launch
                    runCatching { AdminHttpClient.refreshMe(id, profilesStore) }
                }
                while (true) {
                    _timerText.value = FormatUtils.formatDuration(
                        Duration.between(since, Instant.now()).seconds,
                    )
                    delay(1000)
                }
            }
        }

        // Switching the active profile while the tunnel is up reconnects to the
        // new one. If the running profile was deleted — just stop.
        viewModelScope.launch {
            var prev = profilesStore.activeId.value
            profilesStore.activeId.collect { id ->
                val old = prev
                prev = id
                if (old == null || id == old || !isRunning(VpnStateManager.state.value)) return@collect
                stopVpn()
                if (id == null || profilesStore.profiles.value.none { it.id == old }) return@collect
                withTimeoutOrNull(15_000) {
                    VpnStateManager.state.first { it is VpnState.Disconnected || it is VpnState.Error }
                } ?: return@collect
                startVpn()
            }
        }
    }

    private fun sinceOf(state: VpnState): Instant? = when (state) {
        is VpnState.Connected -> state.since
        is VpnState.Stale -> state.since
        is VpnState.Throttled -> state.since
        else -> null
    }

    private fun isRunning(state: VpnState): Boolean = state !is VpnState.Disconnected &&
        state !is VpnState.Disconnecting && state !is VpnState.Error

    fun dismissPreflightWarning() { _preflightWarning.value = null }

    fun startVpn() {
        // v0.27.0 (W5): refuse a fresh start when we're mid-transition or
        // already up. The Dashboard FAB and widget are now disabled in
        // Disconnecting and route Connecting taps to stopVpn, but external
        // entry points (BootReceiver, TileService) could still drive
        // a race. This guard is the floor.
        if (isRunning(VpnStateManager.state.value) ||
            VpnStateManager.state.value is VpnState.Disconnecting
        ) return
        // Built from the store right now, not from a combined flow: right after
        // a profile switch such a flow may still carry the old profile's TUN,
        // DNS and cert paths.
        var profile = profilesStore.getActiveProfile()
        var cfg = configOf(profile, prefs.value ?: return)
        if (cfg.serverAddr.isBlank()) return
        val ctx = getApplication<Application>()

        if (profile != null) {
            // Restore cert files from inline PEM if they were deleted (e.g. app update)
            val certExists = java.io.File(profile.certPath).exists()
            val keyExists = java.io.File(profile.keyPath).exists()
            if (!certExists || !keyExists) {
                val restored = profilesStore.ensureCertFiles(profile)
                if (restored == null) {
                    _preflightWarning.value = ctx.getString(R.string.preflight_certs_lost)
                    VpnStateManager.update(VpnState.Error(ctx.getString(R.string.error_certs_missing)))
                    return
                }
                profile = restored
                cfg = cfg.copy(certPath = restored.certPath, keyPath = restored.keyPath)
            }
            // Subscription and enabled flag are not checked here: the cache can
            // only be refreshed through a working tunnel, so a stale "expired"
            // would lock the user out after the admin extended it. The server
            // refuses a revoked client itself and the core reports why.
        }

        startJob = viewModelScope.launch {
            _preflightWarning.value = null
            VpnStateManager.update(VpnState.Connecting)
            val directCidrsPath = if (cfg.splitRouting && cfg.directCountries.isNotEmpty()) {
                var missing = withContext(Dispatchers.IO) {
                    routingRulesManager.missingSelectedLists(cfg.directCountries)
                }
                if (missing.isNotEmpty()) {
                    // Докачиваем на месте — раньше тут был хард-стоп с отсылкой в Настройки.
                    missing.forEach { routingRulesManager.downloadRuleList(it) }
                    missing = withContext(Dispatchers.IO) {
                        routingRulesManager.missingSelectedLists(cfg.directCountries)
                    }
                }
                if (missing.isNotEmpty()) {
                    _preflightWarning.value =
                        ctx.getString(R.string.preflight_lists_failed, missing.joinToString(", "))
                    VpnStateManager.update(VpnState.Error(ctx.getString(R.string.error_lists_missing)))
                    return@launch
                } else {
                    // Протухшие обновляем в фоне: подключение ждать не должно,
                    // свежий список пригодится к следующему разу.
                    val stale = withContext(Dispatchers.IO) {
                        routingRulesManager.staleSelectedLists(cfg.directCountries)
                    }
                    if (stale.isNotEmpty()) {
                        viewModelScope.launch { stale.forEach { routingRulesManager.downloadRuleList(it) } }
                    }
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

            val intent = Intent(ctx, GhostStreamVpnService::class.java).apply {
                action = GhostStreamVpnService.ACTION_START
                putExtra(GhostStreamVpnService.EXTRA_SERVER_ADDR, cfg.serverAddr)
                putExtra(GhostStreamVpnService.EXTRA_SERVER_NAME,
                    cfg.serverName.ifBlank { cfg.serverAddr.substringBefore(":") })
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
                // DPI recycle (W11) is gone from the UI; a value saved back then
                // must not keep driving reconnect storms, so it is not passed.
            }
            ctx.startForegroundService(intent)
        }
    }

    fun stopVpn() {
        // Still in preflight (rule lists download etc.) — the service hasn't
        // been asked to start yet, so cancelling the job is the whole stop.
        if (startJob?.isActive == true) {
            startJob?.cancel()
            VpnStateManager.update(VpnState.Disconnected)
            return
        }
        // v0.27.0 (W5): no-op if we're already tearing down or off.
        // The user's only legit reason to tap "Disconnect" from these
        // states is impatience — Service.ACTION_STOP is idempotent but
        // a redundant Intent still churns startService binder traffic.
        when (VpnStateManager.state.value) {
            is VpnState.Disconnecting,
            is VpnState.Disconnected -> return
            else -> Unit
        }
        VpnStateManager.update(VpnState.Disconnecting)
        val ctx = getApplication<Application>()
        ctx.startService(Intent(ctx, GhostStreamVpnService::class.java).apply {
            action = GhostStreamVpnService.ACTION_STOP
        })
    }
}
