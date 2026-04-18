package com.ghoststream.vpn.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.widget.WidgetState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * Push-based callback interface implemented by GhostStreamVpnService.
 * Rust calls these methods when status or log frames arrive, instead of
 * the old polling approach.
 */
interface PhantomListener {
    fun onStatusFrame(json: String)
    fun onLogFrame(json: String)
}

class GhostStreamVpnService : VpnService(), PhantomListener {

    private data class StartExtras(
        val serverAddr: String,
        val serverName: String,
        val insecure: Boolean,
        val certPath: String,
        val keyPath: String,
        val tunAddr: String,
        val dnsServers: List<String>,
        val splitRouting: Boolean,
        val directCidrs: String,
        val perAppMode: String,
        val perAppList: List<String>,
        /** Original ghs:// connection string — required for Phase 4 nativeStart. */
        val connString: String = "",
        /** Relay host:port — when set, TCP connects here instead of serverAddr (SNI passthrough). */
        val relayAddr: String = "",
    ) {
        fun toJson(): String = JSONObject().apply {
            put("server_addr", serverAddr); put("server_name", serverName)
            put("insecure", insecure); put("cert_path", certPath); put("key_path", keyPath)
            put("tun_addr", tunAddr); put("dns_servers", dnsServers.joinToString(","))
            put("split_routing", splitRouting); put("direct_cidrs", directCidrs)
            put("per_app_mode", perAppMode); put("per_app_list", perAppList.joinToString(","))
            put("conn_string", connString)
            if (relayAddr.isNotBlank()) put("relay_addr", relayAddr)
        }.toString()

        companion object {
            fun fromJson(raw: String): StartExtras? = runCatching {
                val o = JSONObject(raw)
                StartExtras(
                    serverAddr = o.optString("server_addr"),
                    serverName = o.optString("server_name"),
                    insecure = o.optBoolean("insecure"),
                    certPath = o.optString("cert_path"),
                    keyPath = o.optString("key_path"),
                    tunAddr = o.optString("tun_addr", "10.7.0.2/24"),
                    dnsServers = o.optString("dns_servers", "8.8.8.8,1.1.1.1")
                        .split(",").filter { it.isNotBlank() },
                    splitRouting = o.optBoolean("split_routing"),
                    directCidrs = o.optString("direct_cidrs"),
                    perAppMode = o.optString("per_app_mode", "none"),
                    perAppList = o.optString("per_app_list")
                        .split(",").filter { it.isNotBlank() },
                    connString = o.optString("conn_string", ""),
                    relayAddr = o.optString("relay_addr", ""),
                )
            }.getOrNull()
        }
    }

    private fun resolveStartExtras(intent: Intent?): StartExtras? {
        val serverAddr = intent?.getStringExtra(EXTRA_SERVER_ADDR)
        if (serverAddr != null) {
            val serverName = intent.getStringExtra(EXTRA_SERVER_NAME) ?: serverAddr.substringBefore(":")
            return StartExtras(
                serverAddr = serverAddr,
                serverName = serverName,
                insecure = intent.getBooleanExtra(EXTRA_INSECURE, false),
                certPath = intent.getStringExtra(EXTRA_CERT_PATH) ?: "",
                keyPath = intent.getStringExtra(EXTRA_KEY_PATH) ?: "",
                tunAddr = intent.getStringExtra(EXTRA_TUN_ADDR) ?: "10.7.0.2/24",
                dnsServers = (intent.getStringExtra(EXTRA_DNS_SERVERS) ?: "8.8.8.8,1.1.1.1")
                    .split(",").filter { it.isNotBlank() },
                splitRouting = intent.getBooleanExtra(EXTRA_SPLIT_ROUTING, false),
                directCidrs = intent.getStringExtra(EXTRA_DIRECT_CIDRS) ?: "",
                perAppMode = intent.getStringExtra(EXTRA_PER_APP_MODE) ?: "none",
                perAppList = (intent.getStringExtra(EXTRA_PER_APP_LIST) ?: "")
                    .split(",").filter { it.isNotBlank() },
                connString = intent.getStringExtra(EXTRA_CONN_STRING) ?: "",
                relayAddr = intent.getStringExtra(EXTRA_RELAY_ADDR) ?: "",
            )
        }
        // Restore from saved prefs. Two cases:
        // 1. Null intent — system restarted service after process kill → require wasRunning flag.
        // 2. Non-null intent without extras — explicit start from widget → try prefs regardless.
        val explicitStart = intent != null
        if (!explicitStart) {
            val wasRunning = prefs.wasRunningBlocking()
            if (!wasRunning) return null
        }
        val json = prefs.loadLastTunnelParamsBlocking() ?: return null
        val restored = StartExtras.fromJson(json) ?: return null
        Log.i(TAG, "Restored tunnel params from prefs (explicit=$explicitStart)")
        return restored
    }

    private data class TunnelParams(
        val serverAddr: String,
        val serverName: String,
        val insecure: Boolean,
        val certPath: String,
        val keyPath: String,
        /** Original ghs:// connection string for Phase 4 nativeStart. */
        val connString: String = "",
        /** Relay host:port for SNI passthrough routing. */
        val relayAddr: String = "",
    )

    private data class NativeStatsSnapshot(
        val bytesRx: Long,
        val bytesTx: Long,
        val connected: Boolean,
        val capturedAtMs: Long,
    )

    /** Latest status pushed from Rust via onStatusFrame. Used by the watchdog. */
    @Volatile private var lastStatusJson: String? = null

    private var vpnInterface: ParcelFileDescriptor? = null
    private var watchdogThread: Thread? = null
    private var startupThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var savedParams: TunnelParams? = null
    @Volatile private var savedTunAddr: String = "10.7.0.2/24"
    @Volatile private var savedDnsServers: List<String> = listOf("8.8.8.8", "1.1.1.1")
    @Volatile private var savedSplitRouting: Boolean = false
    @Volatile private var savedDirectCidrs: String = ""
    @Volatile private var savedPerAppMode: String = "none"
    @Volatile private var savedPerAppList: List<String> = emptyList()
    @Volatile private var userStopped = false
    /** Monotonic generation counter — incremented on every start/stop command.
     *  Stale startup threads check this and bail before calling nativeStart. */
    @Volatile private var tunnelGeneration = 0

    // Used by watchdog to sleep-with-wakeup. notifyAll() from network callback or stopTunnel
    // short-circuits exponential backoff so reconnect happens immediately.
    private val watchdogLock = Object()
    @Volatile private var networkChangedTick: Long = 0L

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private lateinit var prefs: PreferencesStore
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Instance method so JNI receives the service object for VpnService.protect().
    // Phase 4: takes cfgJson (ConnectProfile JSON) + settingsJson (TunnelSettings JSON)
    // + a PhantomListener for push-based status/log callbacks.
    external fun nativeStart(
        tunFd: Int,
        cfgJson: String,
        settingsJson: String,
        listener: PhantomListener,
    ): Int

    companion object {
        init {
            System.loadLibrary("phantom_android")
        }

        @JvmStatic external fun nativeStop()
        @JvmStatic external fun nativeGetStats(): String?
        @JvmStatic external fun nativeGetLogs(sinceSeq: Long): String?
        @JvmStatic external fun nativeComputeVpnRoutes(directCidrsPath: String): String?
        @JvmStatic external fun nativeSetLogLevel(level: String)

        const val ACTION_START = "com.ghoststream.vpn.START"
        const val ACTION_STOP  = "com.ghoststream.vpn.STOP"

        const val EXTRA_SERVER_ADDR   = "server_addr"
        const val EXTRA_SERVER_NAME   = "server_name"
        const val EXTRA_INSECURE      = "insecure"
        const val EXTRA_CERT_PATH     = "cert_path"
        const val EXTRA_KEY_PATH      = "key_path"
        const val EXTRA_TUN_ADDR      = "tun_addr"
        const val EXTRA_DNS_SERVERS   = "dns_servers"
        const val EXTRA_SPLIT_ROUTING = "split_routing"
        const val EXTRA_DIRECT_CIDRS  = "direct_cidrs_path"
        const val EXTRA_PER_APP_MODE  = "per_app_mode"
        const val EXTRA_PER_APP_LIST  = "per_app_list"
        /** Phase 4: full ghs:// connection string, used by new nativeStart. */
        const val EXTRA_CONN_STRING   = "conn_string"
        const val EXTRA_RELAY_ADDR    = "relay_addr"

        private const val CHANNEL_ID      = "ghoststream_vpn"
        private const val NOTIFICATION_ID  = 1001
        private const val TAG = "GhostStreamVpn"
        // Safety cap: too many addRoute() entries can overflow Binder transaction
        // in VpnService.Builder.establish() and crash with TransactionTooLargeException.
        private const val MAX_SPLIT_ROUTES = 8000
    }

    // ── PhantomListener implementation ────────────────────────────────────────

    /**
     * Called from Rust when the tunnel status changes. Parses the StatusFrame JSON
     * and updates VpnStateManager accordingly.
     *
     * TODO (Phase 5): subscribe DashboardViewModel to VpnStateManager.statusFrame
     * instead of polling nativeGetStats().
     */
    override fun onStatusFrame(json: String) {
        Log.d(TAG, "status: $json")
        // Store for watchdog polling via readNativeStats().
        lastStatusJson = json
        // Push to VpnStateManager so DashboardViewModel can observe.
        VpnStateManager.pushStatusFrame(json)
        // Push to home screen widgets.
        val frame = StatusFrameData.fromJson(json)
        if (frame != null) {
            serviceScope.launch {
                val isConn = frame.state == "connected"
                val isConning = frame.state == "connecting"
                WidgetState.push(
                    context = applicationContext,
                    connected = isConn,
                    connecting = isConning,
                    serverName = savedParams?.serverName ?: "",
                    timer = formatTimer(frame.sessionSecs),
                    rxSpeed = formatSpeed(frame.rateRxBps),
                    txSpeed = formatSpeed(frame.rateTxBps),
                    streamsUp = frame.streamsUp,
                    streamsTotal = frame.nStreams,
                )
            }
        }
    }

    override fun onLogFrame(json: String) {
        Log.d(TAG, "log: $json")
        // Push to VpnStateManager so LogsViewModel can observe.
        VpnStateManager.pushLogFrame(json)
    }

    override fun onCreate() {
        super.onCreate()
        prefs = PreferencesStore(applicationContext)
        registerNetworkCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // User-initiated stop: clear persistence flag so BootReceiver won't resurrect us.
            serviceScope.launch { runCatching { prefs.setWasRunning(false) } }
            stopTunnelAsync()
            return START_NOT_STICKY
        }

        // Must call startForeground() before anything else when started via
        // startForegroundService(). Android kills the app if we don't within 5 s.
        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID, buildNotification("Подключение..."),
                FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Подключение..."))
        }

        // Resolve extras — either from intent, or restored from prefs if system re-created us with null intent.
        val resolved = resolveStartExtras(intent) ?: run {
            Log.w(TAG, "onStartCommand: no params to start with")
            stopSelf()
            return START_NOT_STICKY
        }

        val serverAddr     = resolved.serverAddr
        val serverName     = resolved.serverName
        val insecure       = resolved.insecure
        val certPath       = resolved.certPath
        val keyPath        = resolved.keyPath
        val tunAddr        = resolved.tunAddr
        val dnsServers     = resolved.dnsServers
        val splitRouting   = resolved.splitRouting
        val directCidrs    = resolved.directCidrs
        val perAppMode     = resolved.perAppMode
        val perAppList     = resolved.perAppList

        // Persist for crash recovery + BootReceiver.
        serviceScope.launch {
            runCatching {
                prefs.setWasRunning(true)
                prefs.saveLastTunnelParams(resolved.toJson())
            }
        }

        val connString = resolved.connString
        val relayAddr = resolved.relayAddr
        val myGeneration = ++tunnelGeneration
        startupThread?.interrupt()
        startupThread = Thread {
            startTunnel(
                serverAddr, serverName, insecure, certPath, keyPath,
                tunAddr, dnsServers, splitRouting, directCidrs, perAppMode, perAppList,
                connString, relayAddr, myGeneration,
            )
        }.apply {
            name = "vpn-startup"
            isDaemon = true
            start()
        }
        return START_STICKY
    }

    private fun startTunnel(
        serverAddr: String, serverName: String,
        insecure: Boolean, certPath: String, keyPath: String,
        tunAddr: String, dnsServers: List<String>,
        splitRouting: Boolean, directCidrsPath: String,
        perAppMode: String, perAppList: List<String>,
        connString: String = "",
        relayAddr: String = "",
        generation: Int = -1,
    ) {
        val parts     = tunAddr.split("/")
        val tunIp     = parts.getOrElse(0) { "10.7.0.2" }
        val tunPrefix = parts.getOrNull(1)?.toIntOrNull() ?: 24

        val builder = Builder()
            .setSession("GhostStream")
            .addAddress(tunIp, tunPrefix)
            .setMtu(1350)

        // ── Routing ──────────────────────────────────────────────────────
        if (splitRouting && directCidrsPath.isNotBlank()) {
            val routesJson = nativeComputeVpnRoutes(directCidrsPath)
            if (routesJson != null) {
                try {
                    val arr = JSONArray(routesJson)
                    if (arr.length() > MAX_SPLIT_ROUTES) {
                        val msg = "Слишком большой список маршрутов (${arr.length()}). " +
                            "Выберите меньше стран для раздельной маршрутизации."
                        Log.e(TAG, msg)
                        VpnStateManager.update(VpnState.Error(msg))
                        stopForeground(STOP_FOREGROUND_REMOVE)
                        stopSelf()
                        return
                    }
                    var count = 0
                    for (i in 0 until arr.length()) {
                        val obj = arr.getJSONObject(i)
                        builder.addRoute(obj.getString("addr"), obj.getInt("prefix"))
                        count++
                    }
                    Log.i(TAG, "Split routing: $count VPN routes added")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to parse VPN routes, falling back to full tunnel", e)
                    builder.addRoute("0.0.0.0", 0)
                }
            } else {
                Log.w(TAG, "nativeComputeVpnRoutes returned null, falling back to full tunnel")
                builder.addRoute("0.0.0.0", 0)
            }
        } else {
            builder.addRoute("0.0.0.0", 0)
        }

        // ── DNS ──────────────────────────────────────────────────────────
        for (dns in dnsServers) {
            try { builder.addDnsServer(dns) } catch (_: Exception) {}
        }

        // ── Per-app routing ──────────────────────────────────────────────
        when (perAppMode) {
            "allowed" -> {
                for (pkg in perAppList) {
                    try { builder.addAllowedApplication(pkg) } catch (_: Exception) {}
                }
                Log.i(TAG, "Per-app: ${perAppList.size} allowed apps")
            }
            "disallowed" -> {
                for (pkg in perAppList) {
                    try { builder.addDisallowedApplication(pkg) } catch (_: Exception) {}
                }
                Log.i(TAG, "Per-app: ${perAppList.size} excluded apps")
            }
        }

        // КРИТИЧНО: резолвим hostname ДО builder.establish(). После establish()
        // activeNetwork становится VPN, и resolveServerAddrViaUnderlying() не
        // сможет найти не-VPN сеть для DNS. Без этого Rust получает hostname
        // вместо IP и его DNS-запрос идёт через мёртвый TUN → "No address".
        // Relay: если задан relayAddr, резолвим его — Rust подключится к relay,
        // а SNI останется от exit-сервера (SNI passthrough).
        val effectiveAddr = if (relayAddr.isNotBlank()) {
            // Если relay без порта — берём порт из serverAddr
            val relayWithPort = if (!relayAddr.contains(':')) {
                val serverPort = serverAddr.substringAfterLast(':', "443")
                "$relayAddr:$serverPort"
            } else relayAddr
            Log.i(TAG, "Relay mode: routing via $relayWithPort")
            VpnStateManager.emitLifecycleLog("INFO", "Relay: $relayWithPort")
            val resolved = resolveServerAddrViaUnderlying(relayWithPort)
            Log.i(TAG, "Relay resolved: $resolved")
            resolved
        } else {
            resolveServerAddrViaUnderlying(serverAddr)
        }

        // Bail if a newer start/stop has been issued while we were setting up.
        if (generation >= 0 && tunnelGeneration != generation) {
            Log.i(TAG, "startTunnel: superseded by generation $tunnelGeneration (mine=$generation), aborting")
            return
        }

        // Close any previous VPN interface before creating a replacement.
        // Android restores default routes when the TUN fd is closed; leaving
        // an old one open leaks the fd and may leave stale routes that block
        // internet after disconnect (the "broken VPN, no internet" state).
        val oldIface = vpnInterface
        vpnInterface = null
        runCatching { oldIface?.close() }

        vpnInterface = builder.establish() ?: run {
            VpnStateManager.update(VpnState.Error("Не удалось создать TUN"))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        userStopped = false
        savedTunAddr = tunAddr
        savedDnsServers = dnsServers
        savedSplitRouting = splitRouting
        savedDirectCidrs = directCidrsPath
        savedPerAppMode = perAppMode
        savedPerAppList = perAppList
        savedParams = TunnelParams(
            serverAddr = serverAddr,
            serverName = serverName,
            insecure = insecure,
            certPath = certPath,
            keyPath = keyPath,
            connString = connString,
            relayAddr = relayAddr,
        )

        val fd = vpnInterface!!.fd
        // Phase 4: build ConnectProfile JSON for the new nativeStart.
        val cfgJson = buildConnectProfileJson(name = serverName, connString = connString, serverAddr = effectiveAddr)
        val settingsJson = """{"dns_leak_protection":true,"ipv6_killswitch":true,"auto_reconnect":true}"""
        val result = nativeStart(fd, cfgJson, settingsJson, this)
        if (result != 0) {
            vpnInterface?.close()
            vpnInterface = null
            VpnStateManager.update(VpnState.Error(nativeStartErrorMessage(result)))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        // Watchdog will transition to Connected once Rust reports state=connected.
        // Note: VpnState.Connecting was already set by DashboardViewModel.startVpn()
        // before the service intent was sent, so no update needed here.

        startWatchdog(serverName, serverAddr)
    }

    /**
     * Monitors native tunnel state and drives VpnState transitions:
     * - Connecting → Connected when handshake succeeds (IS_CONNECTED=true)
     * - Connected → Connecting + auto-reconnect (exponential backoff) if tunnel drops
     * - Connecting → Error after 60s timeout if handshake never completes
     */
    private fun startWatchdog(serverName: String, serverAddr: String) {
        watchdogThread?.interrupt()
        watchdogThread = Thread {
            var wasConnected = false
            var timeoutSecs = 60
            outer@ while (!Thread.currentThread().isInterrupted) {
                if (!watchdogSleep(1000L)) break@outer
                try {
                    val params = savedParams ?: continue
                    val stats = readNativeStats() ?: continue
                    val connected = stats.connected
                    if (connected && !wasConnected) {
                        wasConnected = true
                        timeoutSecs = Int.MAX_VALUE
                        Log.i(TAG, "Tunnel connected to $serverAddr")
                        mainHandler.post {
                            VpnStateManager.update(VpnState.Connected(serverName = serverName))
                            val nm = getSystemService(NotificationManager::class.java)
                            nm?.notify(
                                NOTIFICATION_ID,
                                buildNotification("Подключено: $serverAddr"),
                            )
                        }
                    }
                    if (!connected && wasConnected) {
                        wasConnected = false
                        Log.i(TAG, "Tunnel lost connection, starting reconnect")
                        VpnStateManager.emitLifecycleLog("WARN", "Соединение потеряно, переподключение...")
                        mainHandler.post {
                            VpnStateManager.update(VpnState.Connecting)
                            getSystemService(NotificationManager::class.java)
                                ?.notify(NOTIFICATION_ID, buildNotification("Переподключение..."))
                        }
                        // Exponential backoff: 3s, 6s, 12s, 24s, 48s, 60s, 60s, 60s.
                        // Attempt counter НЕ увеличивается пока сеть недоступна —
                        // иначе 8 попыток сгорают за ~3.5 мин с выключенным WiFi,
                        // что приводит к failTunnel и ложной "ошибке таймаута".
                        var backoffMs = 3_000L
                        var reconnected = false
                        var attempt = 0
                        while (attempt < 8) {
                            if (!hasUsableNetwork()) {
                                Log.i(TAG, "No usable network — parking reconnect until onAvailable")
                                VpnStateManager.emitLifecycleLog("WARN", "Нет сети — ожидание подключения...")
                                if (!waitForUsableNetwork()) break@outer
                                // Сеть появилась — пробуем сразу, без exponential задержки.
                                backoffMs = 3_000L
                            }
                            if (!watchdogSleep(backoffMs)) break@outer
                            if (userStopped) break@outer
                            if (!hasUsableNetwork()) continue  // пропала пока спали
                            attempt++
                            if (restartNativeTunnel(params)) {
                                timeoutSecs = 60
                                reconnected = true
                                break
                            }
                            backoffMs = minOf(backoffMs * 2, 60_000L)
                        }
                        if (!reconnected) {
                            VpnStateManager.emitLifecycleLog("ERROR", "8 попыток реконнекта исчерпаны")
                            mainHandler.post { failTunnel("Не удалось переподключиться к серверу") }
                            break@outer
                        }
                        continue@outer
                    }
                    // Не декрементируем таймаут пока underlying сеть недоступна —
                    // иначе 60-секундный бюджет сгорает за время простоя WiFi.
                    if (hasUsableNetwork()) timeoutSecs--
                    if (!connected && timeoutSecs <= 0) {
                        VpnStateManager.emitLifecycleLog("ERROR", "Тайм-аут 60с: сервер не ответил")
                        mainHandler.post { failTunnel("Тайм-аут подключения к серверу") }
                        break
                    }
                } catch (_: Exception) {}
            }
        }.apply {
            name = "vpn-watchdog"
            isDaemon = true
            start()
        }
    }

    private fun restartNativeTunnel(params: TunnelParams): Boolean {
        if (userStopped) return false
        val iface = vpnInterface ?: return false
        nativeStop()
        if (userStopped) return false
        val effectiveAddr = if (params.relayAddr.isNotBlank()) {
            val relayWithPort = if (!params.relayAddr.contains(':')) {
                val serverPort = params.serverAddr.substringAfterLast(':', "443")
                "${params.relayAddr}:$serverPort"
            } else params.relayAddr
            resolveServerAddrViaUnderlying(relayWithPort)
        } else {
            resolveServerAddrViaUnderlying(params.serverAddr)
        }
        // Phase 4: build ConnectProfile JSON for the new nativeStart.
        val cfgJson = buildConnectProfileJson(name = params.serverName, connString = params.connString, serverAddr = effectiveAddr)
        val settingsJson = """{"dns_leak_protection":true,"ipv6_killswitch":true,"auto_reconnect":true}"""
        val result = nativeStart(iface.fd, cfgJson, settingsJson, this)
        if (result == 0) {
            Log.i(TAG, "Tunnel restarted")
            VpnStateManager.emitLifecycleLog("INFO", "Туннель перезапущен")
            return true
        }
        val errMsg = nativeStartErrorMessage(result)
        Log.w(TAG, "Tunnel restart failed: code=$result ($errMsg)")
        VpnStateManager.emitLifecycleLog("ERROR", "Перезапуск не удался: $errMsg")
        return false
    }

    private fun readNativeStats(): NativeStatsSnapshot? {
        // Phase 4: nativeGetStats() is a stub (returns null). Read from the
        // push-based lastStatusJson populated by onStatusFrame() instead.
        val statusJson = lastStatusJson
        if (statusJson != null) {
            return try {
                val obj = JSONObject(statusJson)
                // StatusFrame from Rust: state = "connected" | "connecting" | "disconnected" | ...
                val stateStr = obj.optString("state", "disconnected")
                val connected = stateStr == "connected"
                NativeStatsSnapshot(
                    bytesRx = obj.optLong("bytes_rx"),
                    bytesTx = obj.optLong("bytes_tx"),
                    connected = connected,
                    capturedAtMs = System.currentTimeMillis(),
                )
            } catch (_: Exception) {
                null
            }
        }
        // Fallback: try old polling path (stub returns null after Phase 4).
        return try {
            val raw = nativeGetStats() ?: return null
            val obj = JSONObject(raw)
            NativeStatsSnapshot(
                bytesRx = obj.optLong("bytes_rx"),
                bytesTx = obj.optLong("bytes_tx"),
                connected = obj.optBoolean("connected"),
                capturedAtMs = System.currentTimeMillis(),
            )
        } catch (_: Exception) {
            null
        }
    }

    /**
     * Build a ConnectProfile JSON string suitable for nativeStart's cfgJson parameter.
     * The conn_string must be a valid ghs:// URL. If blank, Rust will return an error.
     *
     * [serverAddr] is the pre-resolved IP:port from [resolveServerAddrViaUnderlying].
     * We patch the authority in conn_string so Rust doesn't attempt its own DNS
     * resolution (the VPN TUN is already active, DNS would be circular).
     */
    private fun buildConnectProfileJson(name: String, connString: String, serverAddr: String): String {
        val effectiveConnString = patchConnStringAuthority(connString, serverAddr)
        return JSONObject().apply {
            put("name", name)
            put("conn_string", effectiveConnString)
            put("settings", JSONObject().apply {
                put("dns_leak_protection", true)
                put("ipv6_killswitch", true)
                put("auto_reconnect", true)
            })
        }.toString()
    }

    /** Replace the host:port in a ghs:// URL with a pre-resolved address. */
    private fun patchConnStringAuthority(connString: String, resolvedAddr: String): String {
        if (connString.isBlank() || resolvedAddr.isBlank()) return connString
        // ghs://<userinfo>@<host:port>?<query>
        val atIdx = connString.indexOf('@')
        val qIdx = connString.indexOf('?', atIdx.coerceAtLeast(0))
        if (atIdx < 0 || qIdx < 0) return connString
        return connString.substring(0, atIdx + 1) + resolvedAddr + connString.substring(qIdx)
    }

    private fun nativeStartErrorMessage(code: Int): String = when (code) {
        -10 -> "Не удалось запустить поток (ресурсы исчерпаны)"
        else -> "Ошибка запуска туннеля (код $code)"
    }

    /**
     * Public stop called from callers that may be on UI thread. Runs the actual
     * blocking cleanup (nativeStop + fd close) on a dedicated thread with a hard
     * timeout so a stuck native side can't ANR the caller or leave the Service
     * unable to stopSelf().
     */
    private fun stopTunnelAsync(finalState: VpnState = VpnState.Disconnected) {
        tunnelGeneration++ // Invalidate any in-flight startTunnel threads
        userStopped = true
        lastStatusJson = null
        // Push disconnected state to widgets
        serviceScope.launch {
            WidgetState.push(context = applicationContext, connected = false)
        }
        synchronized(watchdogLock) { watchdogLock.notifyAll() }
        startupThread?.interrupt()
        startupThread = null
        watchdogThread?.interrupt()
        watchdogThread = null
        savedParams = null
        if (finalState !is VpnState.Error) {
            mainHandler.post { VpnStateManager.update(VpnState.Disconnecting) }
        }

        // КРИТИЧНО: закрываем tun fd ДО nativeStop. Это заставляет все native
        // read/write на tun получить EBADF и мгновенно разблокирует любой
        // зависший nativeStart/tun-io loop. Без этого при disconnect во время
        // реконнекта сервис продолжает держать tun-интерфейс (иконка ключа в
        // статус-баре остаётся, интернета нет) пока не отработает 3-секундный
        // watchdog на nativeStop.
        val iface = vpnInterface
        vpnInterface = null
        runCatching { iface?.close() }

        Thread {
            val nativeStopDone = Thread {
                runCatching { nativeStop() }
            }.apply { name = "vpn-native-stop"; isDaemon = true; start() }
            nativeStopDone.join(15_000L)
            if (nativeStopDone.isAlive) {
                Log.w(TAG, "nativeStop did not return in 15s — proceeding anyway")
                VpnStateManager.emitLifecycleLog("WARN", "nativeStop завис (15с) — принудительное завершение")
            }
            mainHandler.post {
                VpnStateManager.update(finalState)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }.apply { name = "vpn-stop"; start() }
    }

    // Legacy name retained for onRevoke/onDestroy call sites.
    private fun stopTunnel() = stopTunnelAsync()

    private fun failTunnel(message: String) {
        serviceScope.launch { runCatching { prefs.setWasRunning(false) } }
        stopTunnelAsync(VpnState.Error(message))
    }

    override fun onRevoke() {
        serviceScope.launch { runCatching { prefs.setWasRunning(false) } }
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        unregisterNetworkCallback()
        stopTunnel()
        serviceScope.cancel()
        super.onDestroy()
    }

    // ── Watchdog sleep with wake-up support ────────────────────────────────
    // Returns false if interrupted or userStopped — caller must break its loop.
    private fun watchdogSleep(ms: Long): Boolean {
        val tickAtEntry = networkChangedTick
        val deadline = System.currentTimeMillis() + ms
        synchronized(watchdogLock) {
            while (true) {
                if (userStopped) return false
                if (Thread.currentThread().isInterrupted) return false
                if (networkChangedTick != tickAtEntry) return true // early-wake for fast reconnect
                val remaining = deadline - System.currentTimeMillis()
                if (remaining <= 0L) return true
                try {
                    watchdogLock.wait(remaining)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        @Suppress("UNREACHABLE_CODE") return true
    }

    // ── Network change detection ───────────────────────────────────────────
    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        connectivityManager = cm
        val req = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { wakeWatchdog("onAvailable") }
            override fun onLost(network: Network)      { wakeWatchdog("onLost") }
            override fun onCapabilitiesChanged(n: Network, caps: NetworkCapabilities) {
                // Fires on SIM/Wi-Fi handoff too.
                wakeWatchdog("onCapabilitiesChanged")
            }
        }
        networkCallback = cb
        runCatching { cm.registerNetworkCallback(req, cb) }
            .onFailure { Log.w(TAG, "registerNetworkCallback failed", it) }
    }

    private fun unregisterNetworkCallback() {
        val cm = connectivityManager ?: return
        val cb = networkCallback ?: return
        runCatching { cm.unregisterNetworkCallback(cb) }
        networkCallback = null
    }

    /**
     * Резолвим hostname в IP через underlying (не-VPN) сеть. Это критично при
     * реконнекте после падения/смены сети: если VPN установил свой DNS (10.7.0.1),
     * а tun мёртв, стандартный резолвер зависает. Используем ConnectivityManager
     * для явного выбора не-VPN сети и InetAddress.getByName на её сокете.
     * Возвращает "ip:port" если удалось, иначе исходный "host:port".
     */
    private fun resolveServerAddrViaUnderlying(hostPort: String): String {
        val lastColon = hostPort.lastIndexOf(':')
        if (lastColon <= 0) return hostPort
        val host = hostPort.substring(0, lastColon)
        val port = hostPort.substring(lastColon + 1)
        // Если уже IP — ничего не делаем.
        if (host.matches(Regex("^[0-9.]+$")) || host.contains(':')) return hostPort

        val cm = connectivityManager ?: return hostPort

        // Ищем не-VPN сеть: сначала activeNetwork, потом перебираем allNetworks.
        // Критично при реконнекте: activeNetwork = VPN, но WiFi/LTE всё ещё
        // доступны через allNetworks.
        fun isUsableNonVpn(net: Network): Boolean {
            val caps = cm.getNetworkCapabilities(net) ?: return false
            return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                   caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }

        val net = cm.activeNetwork?.takeIf { isUsableNonVpn(it) }
            ?: cm.allNetworks.firstOrNull { isUsableNonVpn(it) }
            ?: return hostPort

        return runCatching {
            val addrs = net.getAllByName(host)
            val ip = addrs.firstOrNull { it is java.net.Inet4Address }
                ?: addrs.firstOrNull()
                ?: run {
                    Log.w(TAG, "DNS resolved $host but no addresses returned")
                    VpnStateManager.emitLifecycleLog("WARN", "DNS: $host — нет адресов")
                    return@runCatching hostPort
                }
            val ipStr = ip.hostAddress ?: return@runCatching hostPort
            val out = if (ip is java.net.Inet6Address) "[$ipStr]:$port" else "$ipStr:$port"
            Log.i(TAG, "Pre-resolved $host → $ipStr via underlying network")
            VpnStateManager.emitLifecycleLog("DEBUG", "DNS: $host → $ipStr")
            out
        }.getOrElse { e ->
            Log.w(TAG, "DNS resolution failed for $host: ${e.message}")
            VpnStateManager.emitLifecycleLog("WARN", "DNS: не удалось разрешить $host — ${e.message}")
            hostPort
        }
    }

    private fun wakeWatchdog(reason: String) {
        Log.i(TAG, "Network changed ($reason) — waking watchdog")
        synchronized(watchdogLock) {
            networkChangedTick += 1
            watchdogLock.notifyAll()
        }
    }

    /** Есть ли не-VPN сеть с INTERNET capability (иначе нет смысла пытаться реконнектиться). */
    private fun hasUsableNetwork(): Boolean {
        val cm = connectivityManager ?: return true
        val net = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(net) ?: return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) return false
        // Исключаем наш же VPN (его transport = VPN).
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)) return false
        return true
    }

    /** Блокируется на watchdogLock пока сеть не появится (или userStopped). */
    private fun waitForUsableNetwork(): Boolean {
        synchronized(watchdogLock) {
            while (!userStopped && !hasUsableNetwork()) {
                try {
                    watchdogLock.wait(30_000L)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        return !userStopped
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "GhostStream VPN", NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Статус VPN-туннеля" }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun formatTimer(secs: Long): String {
        val h = secs / 3600
        val m = (secs % 3600) / 60
        val s = secs % 60
        return "%02d:%02d:%02d".format(h, m, s)
    }

    private fun formatSpeed(bps: Double): String {
        if (bps <= 0) return "--"
        return when {
            bps >= 1_000_000 -> "%.1f MB/s".format(bps / 1_000_000)
            bps >= 1_000 -> "%.0f KB/s".format(bps / 1_000)
            else -> "%.0f B/s".format(bps)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, GhostStreamVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)

        return builder
            .setContentTitle("GhostStream")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Отключить", stopIntent).build())
            .build()
    }
}
