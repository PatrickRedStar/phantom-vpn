package com.ghoststream.vpn.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
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
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import com.ghoststream.vpn.BuildConfig
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

internal fun shouldPromoteStatusFrameToConnected(
    currentState: VpnState,
    frame: StatusFrameData,
): Boolean = currentState is VpnState.Connecting && frame.state == "connected"

class GhostStreamVpnService : VpnService(), PhantomListener {

    private data class StartExtras(
        val serverAddr: String,
        val serverName: String,
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
        /** v0.27.0 (W11): byte-triggered session recycle to evade carrier silent-freeze. 0 = off. */
        val dpiRecycleBytes: Long = 0,
    ) {
        fun toJson(): String = JSONObject().apply {
            put("server_addr", serverAddr); put("server_name", serverName)
            put("cert_path", certPath); put("key_path", keyPath)
            put("tun_addr", tunAddr); put("dns_servers", dnsServers.joinToString(","))
            put("split_routing", splitRouting); put("direct_cidrs", directCidrs)
            put("per_app_mode", perAppMode); put("per_app_list", perAppList.joinToString(","))
            put("conn_string", connString)
            if (relayAddr.isNotBlank()) put("relay_addr", relayAddr)
            if (dpiRecycleBytes > 0) put("dpi_recycle_bytes", dpiRecycleBytes)
        }.toString()

        companion object {
            fun fromJson(raw: String): StartExtras? = runCatching {
                val o = JSONObject(raw)
                StartExtras(
                    serverAddr = o.optString("server_addr"),
                    serverName = o.optString("server_name"),
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
                    dpiRecycleBytes = o.optLong("dpi_recycle_bytes", 0),
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
                dpiRecycleBytes = intent.getLongExtra(EXTRA_DPI_RECYCLE_BYTES, 0L),
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
        val certPath: String,
        val keyPath: String,
        /** Original ghs:// connection string for Phase 4 nativeStart. */
        val connString: String = "",
        /** Relay host:port for SNI passthrough routing. */
        val relayAddr: String = "",
        /** v0.27.0 (W11): DPI evasion recycle byte threshold. 0 = off. */
        val dpiRecycleBytes: Long = 0,
    )

    private data class NativeStatsSnapshot(
        val bytesRx: Long,
        val bytesTx: Long,
        val connected: Boolean,
        val capturedAtMs: Long,
    )

    /** Latest status pushed from Rust via onStatusFrame. Used by the watchdog. */
    @Volatile private var lastStatusJson: String? = null

    /** v0.27.0 W4-4: rate-limit `Log.d(TAG, "status: ...")` to 1 per 5 s in
     *  debug builds. Without this, the 250 ms status cadence × ~1 KB JSON
     *  fills the 256 KB logcat ring buffer in ~60 s and evicts every other
     *  diagnostic line — making `adb logcat` useless during debug sessions.
     *  Status frames remain at 4 Hz for UI/watchdog; only the logcat mirror
     *  is throttled. */
    @Volatile private var lastStatusLogMs: Long = 0L

    @Volatile private var vpnInterface: ParcelFileDescriptor? = null
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
    // v0.25.0: AtomicInteger so double-tap Connect can't pass both
    // startTunnel invocations through the staleness guard.
    private val tunnelGeneration = java.util.concurrent.atomic.AtomicInteger(0)

    /** v0.27.0 (W6): true between stopTunnelAsync start and the post-nativeStop
     *  cooldown completing. While set, ACTION_START is dropped — preventing the
     *  rapid Disconnect → Connect race where a fresh `Builder.establish()` ran
     *  in the same Service instance before Android's NetworkAgent had torn
     *  down the previous VPN network slot, leaving the system with a phantom
     *  `tun1 mtu 0` route in network <vpnId> for minutes after. */
    @Volatile private var teardownInProgress: Boolean = false

    /** v0.27.0 (W8): partial wake lock held while the tunnel is up. Samsung
     *  One UI 7 throttles CPU scheduling for backgrounded foreground services
     *  when the screen is locked — Rust telemetry/TLS-read loops were
     *  effectively single-stepped, status frames dropped to ~1 / 30 s, and
     *  apps' TCP sessions over the VPN timed out. The wake lock keeps the
     *  CPU scheduling regular for our UID. Acquired at startTunnel,
     *  released by stopTunnelAsync and onDestroy. Tagged so battery stats
     *  attribute correctly. */
    private var tunnelWakeLock: PowerManager.WakeLock? = null

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
        const val EXTRA_DPI_RECYCLE_BYTES = "dpi_recycle_bytes"

        private const val CHANNEL_ID      = "ghoststream_vpn"
        private const val NOTIFICATION_ID  = 1001
        // v0.27.0 (A3): separate DEFAULT-importance channel + id for the
        // one-shot "connection lost" heads-up alert, distinct from the silent
        // ongoing status notification.
        private const val ALERT_CHANNEL_ID = "ghoststream_vpn_alert"
        private const val ALERT_NOTIFICATION_ID = 1002
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
        if (BuildConfig.DEBUG) {
            // v0.27.0 W4-4: emit at most once per 5 s so the logcat ring
            // buffer keeps room for actual diagnostic events. UI / watchdog
            // get every frame via VpnStateManager.pushStatusFrame() below.
            val now = SystemClock.elapsedRealtime()
            if (now - lastStatusLogMs >= 5_000L) {
                lastStatusLogMs = now
                Log.d(TAG, "status: $json")
            }
        }
        // Store for watchdog polling via readNativeStats().
        lastStatusJson = json
        // Push to VpnStateManager so DashboardViewModel can observe.
        VpnStateManager.pushStatusFrame(json)
        // Push to home screen widgets.
        val frame = StatusFrameData.fromJson(json)
        if (frame != null) {
            syncLifecycleStateFromStatusFrame(frame)
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

    private fun syncLifecycleStateFromStatusFrame(frame: StatusFrameData) {
        if (!shouldPromoteStatusFrameToConnected(VpnStateManager.state.value, frame)) return
        val serverName = savedParams?.serverName ?: ""
        mainHandler.post {
            if (!shouldPromoteStatusFrameToConnected(VpnStateManager.state.value, frame)) return@post
            VpnStateManager.update(VpnState.Connected(serverName = serverName))
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
        startNotificationCollector()
        // v0.27.0 (W4-1): LogPersister is started from MyApplication.onCreate
        // on Application-lifetime scope. Earlier it was started here on
        // serviceScope — but Service.onDestroy() cancels that scope on every
        // Disconnect, leaving the process-singleton LogPersister with its
        // collector coroutine dead while `started=true` blocked re-launch on
        // the next Service.onCreate. Persist file stopped growing after
        // first session.
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // User-initiated stop: clear persistence flag so BootReceiver won't resurrect us.
            serviceScope.launch { runCatching { prefs.setWasRunning(false) } }
            stopTunnelAsync()
            return START_NOT_STICKY
        }

        // v0.27.0 (W6): reject ACTION_START during the teardown cooldown.
        // Without this, a rapid Disconnect→Connect tap delivers ACTION_START
        // to the still-alive Service that's about to stopSelf, cancelling the
        // stop and creating a fresh Builder.establish() before Android's
        // NetworkAgent has cleaned up the previous VPN network slot. The
        // result is a wedged VPN slot with phantom `tun1 mtu 0` routes that
        // can only be cleared by force-stopping the app. UI guards already
        // prevent this from the Dashboard FAB and widget, but external entry
        // points (BootReceiver, future TileService) might still hit here.
        if (teardownInProgress) {
            Log.w(TAG, "onStartCommand: ACTION_START dropped — teardown in progress")
            VpnStateManager.emitLifecycleLog("WARN", "Подключение отклонено — дождитесь завершения отключения")
            // We were started via startForegroundService — we MUST call
            // startForeground() within 5s of that, even if we then immediately
            // stopSelf, otherwise Android kills the process with ANR.
            createNotificationChannel()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID, buildNotification("Отключение..."),
                    FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                startForeground(NOTIFICATION_ID, buildNotification("Отключение..."))
            }
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
        val dpiRecycleBytes = resolved.dpiRecycleBytes
        val myGeneration = tunnelGeneration.incrementAndGet()
        startupThread?.interrupt()
        startupThread = Thread {
            startTunnel(
                serverAddr, serverName, certPath, keyPath,
                tunAddr, dnsServers, splitRouting, directCidrs, perAppMode, perAppList,
                connString, relayAddr, myGeneration, dpiRecycleBytes,
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
        certPath: String, keyPath: String,
        tunAddr: String, dnsServers: List<String>,
        splitRouting: Boolean, directCidrsPath: String,
        perAppMode: String, perAppList: List<String>,
        connString: String = "",
        relayAddr: String = "",
        generation: Int = -1,
        dpiRecycleBytes: Long = 0L,
    ) {
        val parts     = tunAddr.split("/")
        val tunIp     = parts.getOrElse(0) { "10.7.0.2" }
        val tunPrefix = parts.getOrNull(1)?.toIntOrNull() ?: 24

        val builder = Builder()
            .setSession("GhostStream")
            .addAddress(tunIp, tunPrefix)
            // v0.25.0: 1350→1300 — на 5G NSA / некоторых mobile carriers
            // underlying link MTU = 1280, и 1350 приводил к фрагментации/drop.
            // 1300 даёт запас под TLS+TCP+IP headers. Bug #P1-7.
            .setMtu(1300)

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

        // v0.25.0: IPv6 killswitch — default-safe. TUN has no IPv6 listener
        // и IPv6 route в "::/0" → kernel drops packet → effectively killswitch.
        // Без этого IPv6 traffic от apps утекает мимо тоннеля. Применяется
        // во всех ветках routing (full-tunnel + split-routing). Bug #16.
        try {
            builder.addRoute("::", 0)
        } catch (e: Exception) {
            Log.w(TAG, "addRoute(::/0) failed", e)
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
            if (BuildConfig.DEBUG) Log.i(TAG, "Relay mode: routing via $relayWithPort")
            VpnStateManager.emitLifecycleLog("INFO", "Relay: $relayWithPort")
            val resolved = resolveServerAddrViaUnderlying(relayWithPort)
            if (BuildConfig.DEBUG) Log.i(TAG, "Relay resolved: $resolved")
            resolved
        } else {
            resolveServerAddrViaUnderlying(serverAddr)
        }

        // Bail if a newer start/stop has been issued while we were setting up.
        if (generation >= 0 && tunnelGeneration.get() != generation) {
            Log.i(TAG, "startTunnel: superseded by generation ${tunnelGeneration.get()} (mine=$generation), aborting")
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

        // v0.24.0: announce the physical network carrying the tunnel so Android
        // (a) stops reporting the VPN as "no internet" during mobile↔Wi-Fi
        // handoff, (b) attributes data usage correctly, and (c) keeps the
        // tunnel from appearing as its own underlying carrier (which can cause
        // a route loop). If activeNetwork is null (extremely rare race), pass
        // `null` array so Android falls back to "any non-VPN".
        applyUnderlyingNetworks("startTunnel")

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
            certPath = certPath,
            keyPath = keyPath,
            connString = connString,
            relayAddr = relayAddr,
            dpiRecycleBytes = dpiRecycleBytes,
        )

        val fd = vpnInterface!!.fd
        // Phase 4: build ConnectProfile JSON for the new nativeStart. The DPI
        // recycle setting MUST live inside cfg.settings (it's the source of
        // truth on the Rust side — see buildConnectProfileJson comment).
        val cfgJson = buildConnectProfileJson(
            name = serverName,
            connString = connString,
            serverAddr = effectiveAddr,
            dpiRecycleBytes = dpiRecycleBytes,
        )
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

        // v0.27.0 (W8): acquire PARTIAL_WAKE_LOCK now that the tunnel is up.
        // Released in stopTunnelAsync (clean stop) and onDestroy (safety net).
        // Without this Samsung One UI 7 throttles CPU scheduling for our
        // backgrounded foreground service when the screen locks, starving
        // the Rust telemetry / TLS-read loops and timing out apps' TCP
        // sessions through the VPN within minutes.
        acquireTunnelWakeLock()

        // Watchdog will transition to Connected once Rust reports state=connected.
        // Note: VpnState.Connecting was already set by DashboardViewModel.startVpn()
        // before the service intent was sent, so no update needed here.

        startWatchdog(serverName, serverAddr)
    }

    private fun acquireTunnelWakeLock() {
        if (tunnelWakeLock?.isHeld == true) return
        runCatching {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GhostStream:tunnel")
            lock.setReferenceCounted(false)
            lock.acquire()
            tunnelWakeLock = lock
            Log.i(TAG, "tunnel wake lock acquired")
        }.onFailure { Log.w(TAG, "wake lock acquire failed", it) }
    }

    private fun releaseTunnelWakeLock() {
        val lock = tunnelWakeLock ?: return
        tunnelWakeLock = null
        runCatching { if (lock.isHeld) lock.release() }
            .onFailure { Log.w(TAG, "wake lock release failed", it) }
        Log.i(TAG, "tunnel wake lock released")
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
                            if (VpnStateManager.state.value !is VpnState.Connected) {
                                VpnStateManager.update(VpnState.Connected(serverName = serverName))
                            }
                            // Notification is rebuilt by startNotificationCollector
                            // (observes derivedVpnState) — no manual notify here.
                        }
                    }
                    if (!connected && wasConnected) {
                        wasConnected = false
                        Log.i(TAG, "Tunnel lost connection, starting reconnect")
                        VpnStateManager.emitLifecycleLog("WARN", "Соединение потеряно, переподключение...")
                        mainHandler.post {
                            VpnStateManager.update(VpnState.Connecting)
                            // Notification rebuilt by startNotificationCollector.
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
        // Phase 4: build ConnectProfile JSON for the new nativeStart. Carry
        // the DPI recycle setting across watchdog-initiated restarts —
        // without this, an underlying network handoff would drop the user's
        // experiment toggle silently.
        val cfgJson = buildConnectProfileJson(
            name = params.serverName,
            connString = params.connString,
            serverAddr = effectiveAddr,
            dpiRecycleBytes = params.dpiRecycleBytes,
        )
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
    private fun buildConnectProfileJson(
        name: String,
        connString: String,
        serverAddr: String,
        dpiRecycleBytes: Long = 0L,
    ): String {
        val effectiveConnString = patchConnStringAuthority(connString, serverAddr)
        // v0.27.0 (W11): the Rust side reads TunnelSettings from
        // `ConnectProfile.settings`, NOT from the separate settingsJson
        // parameter (that's parsed but immediately discarded as `_settings`
        // — see crates/client-android/src/lib.rs:207). Any DPI knobs MUST
        // land here or they silently revert to defaults.
        return JSONObject().apply {
            put("name", name)
            put("conn_string", effectiveConnString)
            put("settings", JSONObject().apply {
                put("dns_leak_protection", true)
                put("ipv6_killswitch", true)
                put("auto_reconnect", true)
                if (dpiRecycleBytes > 0) put("dpi_recycle_bytes", dpiRecycleBytes)
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
        // v0.27.0 (W6): mark teardown so any racing ACTION_START is dropped.
        // Cleared after the post-nativeStop cooldown (see the spawned thread
        // below) so Android's NetworkAgent has time to fully release the VPN
        // network slot before a fresh tunnel attempts to claim it.
        teardownInProgress = true
        // v0.27.0 (W8): release the tunnel wake lock as soon as we're tearing
        // down. No reason to keep CPU pinned through the 1500 ms cooldown +
        // nativeStop teardown — those don't need real-time scheduling.
        releaseTunnelWakeLock()
        tunnelGeneration.incrementAndGet() // Invalidate any in-flight startTunnel threads
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
            // v0.27.0 (W6): hold the Disconnecting state for an extra 1500ms
            // beyond nativeStop completion so Android's NetworkAgent can fully
            // tear down the VPN network slot before we release the lock.
            // Empirically (from a stuck-state logcat capture) Android needs
            // ~1s after the TUN fd closes to remove all routes from the VPN
            // network and to destroy the agent — without this delay, a
            // tap-to-Connect during that window leaves the slot wedged in a
            // half-destroyed state ("tun1 mtu 0 No such device" for minutes).
            try {
                Thread.sleep(1500L)
            } catch (_: InterruptedException) {
                // benign — Thread.interrupt() from elsewhere
            }
            mainHandler.post {
                VpnStateManager.update(finalState)
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                // teardownInProgress stays true until onDestroy fires. If
                // we reset it here, an ACTION_START racing in between this
                // post and the actual onDestroy would cancel the stop and
                // reuse this dying Service — exactly the bug we're closing.
                // A fresh Service instance starts with teardownInProgress
                // = false (per-instance @Volatile), so the next legitimate
                // tap goes through cleanly.
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
        // v0.27.0 (W8): safety net — stopTunnelAsync already releases on every
        // user-/system-initiated stop, but onDestroy can also fire from system
        // resource pressure with the lock still held. Double-release is safe:
        // releaseTunnelWakeLock() null-checks and isHeld-checks internally.
        releaseTunnelWakeLock()
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
            override fun onAvailable(network: Network) {
                wakeWatchdog("onAvailable")
                // v0.24.0: refresh setUnderlyingNetworks so Android attributes
                // the live TUN to the freshly-available physical network. If
                // the VPN was already on a working carrier, this is a no-op
                // (activeNetwork stays the same).
                applyUnderlyingNetworks("onAvailable")
            }
            override fun onLost(network: Network) {
                wakeWatchdog("onLost")
                applyUnderlyingNetworks("onLost")
            }
            override fun onCapabilitiesChanged(n: Network, caps: NetworkCapabilities) {
                // Fires on SIM/Wi-Fi handoff too.
                wakeWatchdog("onCapabilitiesChanged")
                applyUnderlyingNetworks("onCapabilitiesChanged")
            }
        }
        networkCallback = cb
        runCatching { cm.registerNetworkCallback(req, cb) }
            .onFailure { Log.w(TAG, "registerNetworkCallback failed", it) }
    }

    /**
     * Tell Android which physical (non-VPN) network is carrying our tunnel.
     * Caller invokes after `Builder.establish()` and on every NetworkCallback
     * fire. Idempotent and cheap.
     *
     * Picks `activeNetwork` first; falls back to the first allNetworks entry
     * that has INTERNET + NOT_VPN capabilities. Passes `null` when nothing
     * usable found (Android treats this as "any non-VPN"; better than
     * leaving stale state pointing at a dead Wi-Fi).
     */
    private fun applyUnderlyingNetworks(reason: String) {
        val service = this
        val iface = vpnInterface ?: return
        val cm = connectivityManager ?: getSystemService(ConnectivityManager::class.java) ?: return

        // v0.25.0: prefer NET_CAPABILITY_VALIDATED so we don't pin our tunnel
        // to a captive-portal Wi-Fi which has INTERNET capability but no
        // real connectivity. Fallback to INTERNET-only only if no validated
        // network exists (transient: just connected, validation in progress).
        // Bug #10.
        fun isUsableNonVpn(net: Network): Boolean {
            val caps = cm.getNetworkCapabilities(net) ?: return false
            return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                   caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }

        fun isValidatedNonVpn(net: Network): Boolean {
            val caps = cm.getNetworkCapabilities(net) ?: return false
            return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                   caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                   caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }

        val validated = cm.activeNetwork?.takeIf { isValidatedNonVpn(it) }
            ?: cm.allNetworks.firstOrNull { isValidatedNonVpn(it) }
        val net = validated
            ?: cm.activeNetwork?.takeIf { isUsableNonVpn(it) }
            ?: cm.allNetworks.firstOrNull { isUsableNonVpn(it) }
        val validatedNote = if (validated != null) "validated" else "unvalidated-fallback"

        val networks = if (net != null) arrayOf(net) else null
        val netDesc = if (net != null) {
            val caps = cm.getNetworkCapabilities(net)
            val type = when {
                caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true -> "Wi-Fi"
                caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) == true -> "Cellular"
                caps?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) == true -> "Ethernet"
                else -> "Other"
            }
            "$type/${net.networkHandle}"
        } else {
            "none"
        }
        val ok = runCatching { service.setUnderlyingNetworks(networks) }
            .onFailure { Log.w(TAG, "setUnderlyingNetworks failed", it) }
            .isSuccess
        if (ok) {
            Log.i(TAG, "setUnderlyingNetworks($netDesc) reason=$reason status=$validatedNote")
            VpnStateManager.emitLifecycleLog("INFO", "Сеть: $netDesc ($reason, $validatedNote)")
        }
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
            // v0.25.0: prefer IPv4 explicit — наши серверы v4-only, на
            // IPv6-only сетях (T-Mobile US, Иран) первый возвращённый адрес
            // может быть IPv6 → TCP connect timeout. Bug #9.
            val v4 = addrs.firstOrNull { it is java.net.Inet4Address }
            val v6 = addrs.firstOrNull { it is java.net.Inet6Address }
            val ip = v4 ?: v6
                ?: run {
                    Log.w(TAG, "DNS resolved $host but no addresses returned")
                    VpnStateManager.emitLifecycleLog("WARN", "DNS: $host — нет адресов")
                    return@runCatching hostPort
                }
            val ipStr = ip.hostAddress ?: return@runCatching hostPort
            val out = if (ip is java.net.Inet6Address) "[$ipStr]:$port" else "$ipStr:$port"
            val stack = if (v4 != null) "v4" else "v6-fallback"
            if (BuildConfig.DEBUG) {
                Log.i(
                    TAG,
                    "DNS resolved $host → $ipStr stack=$stack " +
                        "v4=${if (v4 != null) 1 else 0} v6=${if (v6 != null) 1 else 0}",
                )
            }
            VpnStateManager.emitLifecycleLog("DEBUG", "DNS: $host → $ipStr ($stack)")
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
            val nm = getSystemService(NotificationManager::class.java) ?: return
            val channel = NotificationChannel(
                CHANNEL_ID, "GhostStream VPN", NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Статус VPN-туннеля" }
            nm.createNotificationChannel(channel)
            // v0.27.0 (A3): heads-up alert channel for connection-loss events.
            val alert = NotificationChannel(
                ALERT_CHANNEL_ID, "GhostStream — обрывы связи",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply { description = "Уведомления об обрыве VPN-туннеля" }
            nm.createNotificationChannel(alert)
        }
    }

    /** v0.27.0 (A3): one-shot heads-up alert when the tunnel drops under load.
     *  Fired only on the *transition* into a lost state, never per-tick. */
    private fun notifyConnectionLost() {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val openIntent = PendingIntent.getActivity(
            this, 0,
            packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(this, GhostStreamVpnService::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, ALERT_CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = builder
            .setContentTitle("VPN потерял связь")
            .setContentText("Туннель оборвался под нагрузкой сети. Идёт автопереподключение.")
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(openIntent)
            .build()
        runCatching { nm.notify(ALERT_NOTIFICATION_ID, n) }
            .onFailure { Log.w(TAG, "notifyConnectionLost failed", it) }
    }

    /**
     * v0.27.0 (A1/A3): single collector that keeps the ongoing notification
     * honest. On every `derivedVpnState` change it rebuilds the foreground
     * notification (Stale/Throttled/Reconnecting/Dead are reflected, not a
     * static "Connected"). On the transition *from* a connected state *into*
     * Reconnecting it fires the one-shot heads-up "connection lost" alert.
     *
     * This only REFLECTS health — it never triggers reconnect (that's the Rust
     * side: death-watcher + RX_IDLE). The Kotlin watchdog is untouched.
     */
    private fun startNotificationCollector() {
        serviceScope.launch {
            var wasUp = false // last state was Connected/Stale/Throttled
            VpnStateManager.derivedVpnState.collect { state ->
                // Don't resurrect a notification once the tunnel is gone — the
                // teardown path calls stopForeground(REMOVE) itself.
                val nm = getSystemService(NotificationManager::class.java)
                when (state) {
                    is VpnState.Disconnected,
                    is VpnState.Disconnecting -> {
                        wasUp = false
                    }
                    is VpnState.Reconnecting -> {
                        // Only alert on the transition out of a previously-up
                        // tunnel — not on connect-time retries.
                        if (wasUp) {
                            notifyConnectionLost()
                            wasUp = false
                        }
                        nm?.notify(NOTIFICATION_ID, buildNotification(state = state))
                    }
                    is VpnState.Connected,
                    is VpnState.Stale,
                    is VpnState.Throttled -> {
                        wasUp = true
                        nm?.notify(NOTIFICATION_ID, buildNotification(state = state))
                    }
                    else -> {
                        nm?.notify(NOTIFICATION_ID, buildNotification(state = state))
                    }
                }
            }
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

    /**
     * Build the ongoing foreground notification. When [text] is supplied it's
     * used verbatim (legacy call sites: "Подключение...", "Отключение...").
     * Otherwise the title/text/accent are derived honestly from the supplied
     * [VpnState] (which is `derivedVpnState` — already reconciled with the
     * runtime health), so the notification reflects Stale/Throttled/
     * Reconnecting/Dead instead of a static "Connected" lie. v0.27.0 (A1).
     */
    private fun buildNotification(
        text: String? = null,
        state: VpnState? = null,
    ): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, GhostStreamVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)

        val (title, body, accent) = if (text != null) {
            Triple("GhostStream", text, 0)
        } else {
            notificationContentFor(state ?: VpnState.Disconnected)
        }

        builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            // Frequent rebuilds (bytes tick over) must NOT buzz/alert — only
            // the first post of a given content makes a sound.
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Отключить", stopIntent).build())
        if (accent != 0) builder.setColor(accent)
        return builder.build()
    }

    /** Derive (title, text, accentColor) for the ongoing notification from the
     *  honest derived state. accentColor 0 = leave default. */
    private fun notificationContentFor(state: VpnState): Triple<String, String, Int> {
        val frame = VpnStateManager.statusFrame.value
        val green = 0xFF8FE388.toInt()   // signal lime
        val amber = 0xFFE0B24A.toInt()
        val red = 0xFFE05A4A.toInt()
        return when (state) {
            is VpnState.Connected -> {
                val rx = formatSpeed(frame.rateRxBps)
                val tx = formatSpeed(frame.rateTxBps)
                Triple(
                    "Защищено",
                    "↓$rx ↑$tx · ${frame.streamsUp}/${frame.nStreams} стримов",
                    green,
                )
            }
            is VpnState.Stale -> Triple(
                "Канал замолчал (${state.idleRxSecs} с)",
                "Нет входящих данных, проверяю связь",
                amber,
            )
            is VpnState.Throttled -> Triple(
                "Скорость ограничена (~${state.currentKbps} кбит/с)",
                "Сеть жива, но душит трафик",
                amber,
            )
            is VpnState.Reconnecting -> {
                // DEAD health collapses into Reconnecting in derivedVpnState;
                // distinguish it for honest wording. A "dead" tunnel (all
                // streams down, no reconnect attempt counter yet) reads
                // differently from a counted backoff retry.
                if (frame.health == TunnelHealth.DEAD && state.attempt <= 0) {
                    Triple(
                        "Связь потеряна, восстанавливаю",
                        "Трафик не идёт, туннель пересоздаётся",
                        red,
                    )
                } else {
                    val attempt = state.attempt.coerceAtLeast(1)
                    val delay = state.nextDelaySecs
                    val sub = if (delay != null) "Следующая попытка через $delay с"
                              else "Восстанавливаю соединение"
                    Triple("Переподключение… (попытка $attempt/8)", sub, red)
                }
            }
            is VpnState.Connecting -> Triple("GhostStream", "Подключение...", 0)
            is VpnState.Disconnecting -> Triple("GhostStream", "Отключение...", 0)
            is VpnState.Error -> Triple("GhostStream", "Ошибка: ${state.message}", red)
            is VpnState.Disconnected -> Triple("GhostStream", "Отключено", 0)
        }
    }
}
