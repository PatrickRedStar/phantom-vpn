package com.ghoststream.vpn.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
import android.net.ConnectivityManager
import android.net.IpPrefix
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
import android.provider.Settings
import android.util.Log
import androidx.annotation.RequiresApi
import com.ghoststream.vpn.BuildConfig
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.ConnStringParser
import com.ghoststream.vpn.data.PreferencesStore
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.widget.WidgetState
import java.io.File
import java.net.Inet4Address
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
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

/** Writes that must outlive the service: serviceScope is cancelled in onDestroy,
 *  milliseconds after onRevoke / stopSelf, and would drop them mid-flight. */
private val persistScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

/** Last validated IP per server host — used when no network can resolve it. */
private val resolvedCache = ConcurrentHashMap<String, String>()

class GhostStreamVpnService : VpnService(), PhantomListener {

    private data class StartExtras(
        val serverAddr: String,
        val serverName: String,
        val tunAddr: String,
        val dnsServers: List<String>,
        val splitRouting: Boolean,
        val directCidrs: String,
        val perAppMode: String,
        val perAppList: List<String>,
        /** Original ghs:// connection string — carries cert + key for nativeStart. */
        val connString: String,
        /** Relay host:port — when set, TCP connects here instead of serverAddr (SNI passthrough). */
        val relayAddr: String = "",
    )

    private fun startExtrasFromIntent(intent: Intent?): StartExtras? {
        val serverAddr = intent?.getStringExtra(EXTRA_SERVER_ADDR) ?: return null
        return StartExtras(
            serverAddr = serverAddr,
            serverName = intent.getStringExtra(EXTRA_SERVER_NAME) ?: serverAddr.substringBefore(":"),
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

    /**
     * Start without explicit params (widget, boot, always-on, restart after a
     * process kill): the live active profile, read the same way the dashboard
     * reads it. Nothing is snapshotted — a deleted profile can't come back, and
     * the private key stays in exactly one place. Blocking IO — call off main.
     */
    private fun startExtrasFromStore(): StartExtras? {
        val store = ProfilesStore.getInstance(this)
        val profile = store.getActiveProfile()?.let { store.ensureCertFiles(it) } ?: return null
        val connString = ConnStringParser.build(profile) ?: return null
        val global = runBlocking { prefs.config.first() }
        val split = profile.splitRouting ?: global.splitRouting
        val countries = profile.directCountries ?: global.directCountries
        // Lists not downloaded → full tunnel: extra traffic via exit beats a leak.
        val directPath = if (split && countries.isNotEmpty()) {
            RoutingRulesManager(this).mergeSelectedLists(countries).orEmpty()
        } else ""
        return StartExtras(
            serverAddr = profile.serverAddr,
            serverName = profile.serverName.ifBlank { profile.serverAddr.substringBefore(":") },
            tunAddr = profile.tunAddr,
            dnsServers = profile.dnsServers ?: global.dnsServers,
            splitRouting = split,
            directCidrs = directPath,
            perAppMode = profile.perAppMode ?: global.perAppMode,
            perAppList = profile.perAppList ?: global.perAppList,
            connString = connString,
            relayAddr = if (profile.relayEnabled) profile.relayAddr.orEmpty() else "",
        )
    }

    private data class TunnelParams(
        val serverName: String,
        val serverAddr: String,
        /** Original ghs:// connection string for nativeStart. */
        val connString: String,
        /** Relay host:port for SNI passthrough routing. */
        val relayAddr: String,
    )

    /** v0.27.0 W4-4: rate-limit `Log.d(TAG, "status: ...")` to 1 per 5 s in
     *  debug builds. Without this, the 250 ms status cadence × ~1 KB JSON
     *  fills the 256 KB logcat ring buffer in ~60 s and evicts every other
     *  diagnostic line — making `adb logcat` useless during debug sessions.
     *  Status frames remain at 4 Hz for UI; only the logcat mirror
     *  is throttled. */
    @Volatile private var lastStatusLogMs: Long = 0L

    /** Widgets get a state change at once, refreshed numbers at most every 5 s. */
    @Volatile private var lastWidgetState: String? = null
    @Volatile private var lastWidgetPushMs: Long = 0L

    @Volatile private var vpnInterface: ParcelFileDescriptor? = null
    /** Guards swapping [vpnInterface] together with the generation check. */
    private val ifaceLock = Object()
    private var startupThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var savedParams: TunnelParams? = null
    /** ip:port the native tunnel was started with; null — not started. */
    @Volatile private var currentServerAddr: String? = null
    /** Monotonic generation counter — incremented on every start/stop command.
     *  Stale startup threads check this and bail before calling nativeStart. */
    // v0.25.0: AtomicInteger so double-tap Connect can't pass both
    // startTunnel invocations through the staleness guard.
    private val tunnelGeneration = java.util.concurrent.atomic.AtomicInteger(0)
    /** nativeStart (with its generation check) and nativeStop never interleave:
     *  a start that passed the check before a stop is stopped right after it. */
    private val nativeLock = Object()

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

    /**
     * Physical (non-VPN) networks as reported by our network callback. Not
     * `activeNetwork`: with the TUN up that is our own VPN. Reconnecting is the
     * Rust core's job (it retries forever); this map only tells us where the
     * server name can be resolved honestly.
     */
    private val physicalNetworks = ConcurrentHashMap<Network, NetworkCapabilities>()
    /** Notified on every physical-network change; the startup thread waits on it. */
    private val networkLock = Object()
    @Volatile private var captiveHintShown = false

    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private lateinit var prefs: PreferencesStore
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Instance method so JNI receives the service object for VpnService.protect().
    // cfgJson is a ConnectProfile; tunnel settings travel inside it.
    external fun nativeStart(
        tunFd: Int,
        cfgJson: String,
        listener: PhantomListener,
    ): Int

    companion object {
        init {
            System.loadLibrary("phantom_android")
        }

        @JvmStatic external fun nativeStop()
        @JvmStatic external fun nativeComputeVpnRoutes(directCidrsPath: String): String?
        @JvmStatic external fun nativeSetLogLevel(level: String)

        const val ACTION_START = "com.ghoststream.vpn.START"
        const val ACTION_STOP  = "com.ghoststream.vpn.STOP"

        const val EXTRA_SERVER_ADDR   = "server_addr"
        const val EXTRA_SERVER_NAME   = "server_name"
        const val EXTRA_TUN_ADDR      = "tun_addr"
        const val EXTRA_DNS_SERVERS   = "dns_servers"
        const val EXTRA_SPLIT_ROUTING = "split_routing"
        const val EXTRA_DIRECT_CIDRS  = "direct_cidrs_path"
        const val EXTRA_PER_APP_MODE  = "per_app_mode"
        const val EXTRA_PER_APP_LIST  = "per_app_list"
        /** Full ghs:// connection string; cert and key travel inside it. */
        const val EXTRA_CONN_STRING   = "conn_string"
        const val EXTRA_RELAY_ADDR    = "relay_addr"

        private const val CHANNEL_ID      = "ghoststream_vpn"
        private const val NOTIFICATION_ID  = 1001
        // v0.27.0 (A3): separate DEFAULT-importance channel + id for the
        // one-shot alerts, distinct from the silent ongoing status notification.
        private const val ALERT_CHANNEL_ID = "ghoststream_vpn_alert"
        private const val ALERT_NOTIFICATION_ID = 1002
        private const val CAPTIVE_NOTIFICATION_ID = 1003
        /** Short drops (a network handoff) stay quiet; only a longer outage
         *  turns the notification into "Нет связи" and raises the alert. */
        private const val NO_LINK_ALERT_DELAY_MS = 25_000L
        private const val TAG = "GhostStreamVpn"
        // Safety cap: too many addRoute() entries can overflow Binder transaction
        // in VpnService.Builder.establish() and crash with TransactionTooLargeException.
        private const val MAX_SPLIT_ROUTES = 8000

        /**
         * Бюджет маршрутов с учётом ЧУЖИХ процессов.
         *
         * MAX_SPLIT_ROUTES выбирался под лимит одной Binder-транзакции в
         * establish(). Но тот же список уезжает в LinkProperties VPN-сети, а её
         * читает любой процесс через ConnectivityManager — и там свой per-process
         * лимит буфера (~1 МБ). Замер на Z Fold 8: 7982 маршрута → LinkProperties
         * 295 КБ → Настройки падают с "Binder buffer full" при открытии
         * Подключения → Другие настройки. Держим ~17 % лимита.
         */
        private const val ROUTE_BUDGET = 1500

        /**
         * Бюджет для excludeRoute-пути (API 33+). Замер на S21: 12 820 префиксов
         * дают parcel 1 077 464 Б и establish() падает с TransactionTooLargeException
         * — то есть ≈84 Б на запись при лимите Binder в 1 МБ. 10 000 оставляет
         * ~160 КБ запаса под остальное содержимое Builder; geoip ru при этом
         * укладывается со склейкой дырок ≤256 адресов (+0,5 % лишнего).
         *
         * Но узкое место не establish(), а чтение LinkProperties сторонним
         * процессом: 9406 записей дают reply IConnectivityManager в 1 317 500 Б
         * (≈140 Б на запись), Binder этого не переживает и уносит system_server
         * вместе с «Настройками». 6000 записей ≈ 840 КБ — с запасом.
         */
        private const val EXCLUDE_BUDGET = 6000

        /**
         * Потолок склейки exclude-списка: разрыв до 1024 адресов (4 × /24).
         * Ровно столько чужих адресов может уйти мимо туннеля на каждый разрыв;
         * на geoip ru это ≈1,5 млн адресов (0,03 % IPv4) против десятков
         * миллионов при неограниченном росте порога.
         */
        private const val EXCLUDE_MAX_GAP = 1024L

        /** Порог склейки: дырка до /17 (32 768 адресов). Решение владельца 2026-08-01. */
        private const val GAP_MERGE_START = (1L shl 15) - 1
    }

    // ── PhantomListener implementation ────────────────────────────────────────

    /**
     * Called from Rust when the tunnel status changes. Parses the StatusFrame JSON
     * once and fans it out: VpnStateManager (UI), lifecycle, widgets.
     */
    override fun onStatusFrame(json: String) {
        if (BuildConfig.DEBUG) {
            // v0.27.0 W4-4: emit at most once per 5 s so the logcat ring
            // buffer keeps room for actual diagnostic events. UI gets every
            // frame via VpnStateManager.pushStatusFrame() below.
            val now = SystemClock.elapsedRealtime()
            if (now - lastStatusLogMs >= 5_000L) {
                lastStatusLogMs = now
                Log.d(TAG, "status: $json")
            }
        }
        val frame = StatusFrameData.fromJson(json) ?: return
        VpnStateManager.pushStatusFrame(frame)
        syncLifecycleStateFromStatusFrame(frame)
        if (frame.state == "error") scheduleFatalCheck()
        pushWidget(frame)
    }

    private fun syncLifecycleStateFromStatusFrame(frame: StatusFrameData) {
        if (!shouldPromoteStatusFrameToConnected(VpnStateManager.state.value, frame)) return
        val serverName = savedParams?.serverName ?: ""
        mainHandler.post {
            if (!shouldPromoteStatusFrameToConnected(VpnStateManager.state.value, frame)) return@post
            VpnStateManager.update(VpnState.Connected(serverName = serverName))
        }
    }

    /**
     * state=error from the core means a fatal error: broken connection string or
     * config, certificate problem, revoked client, wrong clock. Network errors
     * are retried by the core itself and never surface as error. The one-second
     * wait is insurance: an older core also set error between attempts, but
     * immediately followed it with the delay until the next one.
     */
    private fun scheduleFatalCheck() {
        val generation = tunnelGeneration.get()
        mainHandler.postDelayed({
            val f = VpnStateManager.statusFrame.value
            if (f.state == "error" && f.reconnectNextDelaySecs == null) {
                failTunnel(f.lastError?.takeIf { it.isNotBlank() } ?: "Ошибка туннеля", generation)
            }
        }, 1_000L)
    }

    /** Home-screen widgets: a state change goes out at once; timer and speeds
     *  at most every 5 s, and not at all while the screen is off. */
    private fun pushWidget(frame: StatusFrameData) {
        val now = SystemClock.elapsedRealtime()
        if (frame.state == lastWidgetState &&
            (now - lastWidgetPushMs < 5_000L || getSystemService(PowerManager::class.java)?.isInteractive == false)
        ) return
        lastWidgetState = frame.state
        lastWidgetPushMs = now
        serviceScope.launch {
            WidgetState.push(
                context = applicationContext,
                connected = frame.state == "connected",
                connecting = frame.state == "connecting",
                reconnecting = frame.state == "reconnecting",
                serverName = savedParams?.serverName ?: "",
                timer = formatTimer(frame.sessionSecs),
                rxSpeed = formatSpeed(frame.rateRxBps),
                txSpeed = formatSpeed(frame.rateTxBps),
                streamsUp = frame.streamsUp,
                streamsTotal = frame.nStreams,
            )
        }
    }

    override fun onLogFrame(json: String) {
        if (BuildConfig.DEBUG) Log.d(TAG, "log: $json")
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
            persistScope.launch { runCatching { prefs.setWasRunning(false) } }
            stopTunnelAsync()
            return START_NOT_STICKY
        }

        // Must call startForeground() before anything else when started via
        // startForegroundService(). Android kills the app if we don't within 5 s.
        createNotificationChannel()

        // v0.27.0 (W6): reject ACTION_START during the teardown cooldown.
        // Without this, a rapid Disconnect→Connect tap delivers ACTION_START
        // to the still-alive Service that's about to stopSelf, cancelling the
        // stop and creating a fresh Builder.establish() before Android's
        // NetworkAgent has cleaned up the previous VPN network slot. The
        // result is a wedged VPN slot with phantom `tun1 mtu 0` routes that
        // can only be cleared by force-stopping the app. UI guards already
        // prevent this from the Dashboard FAB and widget, but external entry
        // points (BootReceiver, always-on) might still hit here.
        if (teardownInProgress) {
            Log.w(TAG, "onStartCommand: ACTION_START dropped — teardown in progress")
            VpnStateManager.emitLifecycleLog("WARN", "Подключение отклонено — дождитесь завершения отключения")
            startForegroundCompat(statusContent("Отключение..."))
            return START_NOT_STICKY
        }

        val fromIntent = startExtrasFromIntent(intent)

        // Tunnel is up and nothing new was asked for (widget, autostart or
        // always-on on top of a live tunnel): keep it. Recreating the TUN would
        // only repeat the handshake burst.
        if (fromIntent == null && vpnInterface != null) {
            startForegroundCompat(notificationContentFor(VpnStateManager.derivedVpnState.value))
            return START_STICKY
        }

        startForegroundCompat(statusContent("Подключение..."))

        // Null intent — the system re-created us after a process kill. Only
        // come back if the user hadn't disconnected.
        if (intent == null && !prefs.wasRunningBlocking()) {
            stopSelf()
            return START_NOT_STICKY
        }

        // Whoever started us (UI, widget, boot, always-on) — the user sees
        // "Подключение", not the previous session's leftovers.
        VpnStateManager.resetStatus()
        VpnStateManager.update(VpnState.Connecting)
        persistScope.launch { runCatching { prefs.setWasRunning(true) } }

        val myGeneration = tunnelGeneration.incrementAndGet()
        startupThread?.interrupt()
        startupThread = Thread {
            // An uncaught exception here would kill the whole process. A stop or
            // a newer start interrupts this thread (runBlocking then throws), and
            // reading the profile does file IO.
            try {
                val extras = fromIntent ?: startExtrasFromStore()
                if (extras == null) {
                    mainHandler.post { failTunnel("Нет профиля для подключения — откройте приложение", myGeneration) }
                } else {
                    startTunnel(extras, myGeneration)
                }
            } catch (_: InterruptedException) {
                // Superseded — whoever interrupted us owns the state now.
            } catch (e: Exception) {
                Log.e(TAG, "startup failed", e)
                mainHandler.post { failTunnel("Не удалось запустить туннель: ${e.message}", myGeneration) }
            }
        }.apply {
            name = "vpn-startup"
            isDaemon = true
            start()
        }
        return START_STICKY
    }

    private fun startTunnel(extras: StartExtras, generation: Int) {
        val parts     = extras.tunAddr.split("/")
        val tunIp     = parts.getOrElse(0) { "10.7.0.2" }
        val tunPrefix = parts.getOrNull(1)?.toIntOrNull() ?: 24

        val builder = Builder()
            .setSession("GhostStream")
            .addAddress(tunIp, tunPrefix)
            // v0.25.0: 1350→1300 — на 5G NSA / некоторых mobile carriers
            // underlying link MTU = 1280, и 1350 приводил к фрагментации/drop.
            // 1300 даёт запас под TLS+TCP+IP headers. Bug #P1-7.
            .setMtu(1300)
        // Since targetSdk 29 a VPN counts as metered by default, and Wi-Fi-only
        // jobs (photo backup, Play updates) stop. Inherit it from the real network.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)

        // ── Routing ──────────────────────────────────────────────────────
        // LAN, link-local and multicast (printer, Chromecast, router) bypass the
        // tunnel in every mode: the exit can't deliver them anyway.
        if (extras.splitRouting && extras.directCidrs.isNotBlank() &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
        ) {
            // Перечислить сами direct-подсети дешевле, чем их комплемент: 12–13 тыс.
            // записей против ~30 тыс., и ни одна подсеть не теряется по дороге.
            // Комплемент приходилось резать до ROUTE_BUDGET, и склейка съедала
            // ровно те блоки, ради которых split включают (Яндекс /22 и подобные).
            val excluded = loadExcludePrefixes(extras.directCidrs, EXCLUDE_BUDGET)
            if (excluded.isEmpty()) {
                Log.w(TAG, "Direct list unusable, full tunnel")
                addFullTunnelRoutes(builder)
            } else {
                builder.addRoute("0.0.0.0", 0)
                var applied = 0
                for (p in excluded) {
                    try { builder.excludeRoute(p); applied++ } catch (e: Exception) {
                        Log.w(TAG, "excludeRoute($p) rejected", e)
                    }
                }
                Log.i(TAG, "Split routing: $applied excluded prefixes (API 33+ path)")
            }
        } else if (extras.splitRouting && extras.directCidrs.isNotBlank()) {
            val routesJson = nativeComputeVpnRoutes(extras.directCidrs)
            if (routesJson != null) {
                try {
                    val arr = JSONArray(routesJson)
                    if (arr.length() > MAX_SPLIT_ROUTES) {
                        val msg = "Слишком большой список маршрутов (${arr.length()}). " +
                            "Выберите меньше стран для раздельной маршрутизации."
                        Log.e(TAG, msg)
                        mainHandler.post { failTunnel(msg, generation) }
                        return
                    }
                    // Пустой комплемент = fail-OPEN, а не «нет маршрутов»: такое
                    // бывает, когда direct-список накрывает 0.0.0.0/0 (или /1../7).
                    // Раньше цикл ниже не добавлял НИ ОДНОГО IPv4-маршрута,
                    // establish() проходил, статус показывал «Подключено», а весь
                    // IPv4 шёл мимо туннеля открытым текстом. Полный туннель —
                    // единственный безопасный ответ на пустой список.
                    if (arr.length() == 0) {
                        Log.w(TAG, "Empty VPN route set (direct list covers everything?), full tunnel")
                        addFullTunnelRoutes(builder)
                    } else {
                        // v0.28.1: склейка соседних туннельных блоков перед addRoute.
                        // Rust уже умеет это (compute_vpn_routes_merged), но в APK
                        // лежит prebuilt .so, поэтому страхуемся здесь же — логика
                        // безопасна по построению: расширяется ТУННЕЛЬ, наружу ничего
                        // не выходит. Уберём, когда .so пересоберут с NDK.
                        val merged = mergeSmallGaps(arr, ROUTE_BUDGET)
                        for ((addr, prefix) in merged) {
                            builder.addRoute(addr, prefix)
                        }
                        Log.i(TAG, "Split routing: ${merged.size} VPN routes added (from ${arr.length()})")
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to parse VPN routes, falling back to full tunnel", e)
                    addFullTunnelRoutes(builder)
                }
            } else {
                Log.w(TAG, "nativeComputeVpnRoutes returned null, falling back to full tunnel")
                addFullTunnelRoutes(builder)
            }
        } else {
            addFullTunnelRoutes(builder)
        }

        // IPv6 is not announced at all: no address, no route, no DNS server.
        // VpnService then blocks the whole family by itself (Builder.allowFamily:
        // "by default, if no address, route or DNS server of a specific family is
        // added to this VPN, then all outgoing traffic of that family is
        // blocked") — the kernel answers "unreachable" at once and apps fall back
        // to IPv4. The old addRoute("::", 0) without an address did the opposite:
        // it ENABLED IPv6 in the VPN and sent it into a TUN that can't carry it,
        // where it hung until timeout — strict Private DNS tried DoT over IPv6
        // and name resolution died entirely.

        // ── DNS ──────────────────────────────────────────────────────────
        // IPv4 only: the tunnel is v4-only, and a single IPv6 DNS address would
        // enable the IPv6 family (see above) and let IPv6 traffic bypass the VPN.
        val dnsServers = extras.dnsServers.filter { ipToLong(it) != null }
            .ifEmpty { listOf("8.8.8.8", "1.1.1.1") }
        for (dns in dnsServers) {
            try { builder.addDnsServer(dns) } catch (_: Exception) {}
        }
        // Split mode: a DNS server may fall into the direct list and its queries
        // would go around the tunnel in clear text. Pin each one into the tunnel
        // explicitly (a /32 beats any wider direct prefix). A LAN resolver
        // (the router) stays local.
        if (extras.splitRouting) {
            for (dns in dnsServers) {
                if (!isSpecialAddress(dns)) {
                    try { builder.addRoute(dns, 32) } catch (_: Exception) {}
                }
            }
        }

        // ── Per-app routing ──────────────────────────────────────────────
        when (extras.perAppMode) {
            "allowed" -> {
                // Our own package always rides the tunnel: admin API requests and
                // the DNS health probe must see what the user's apps see.
                for (pkg in (extras.perAppList + packageName).distinct()) {
                    try { builder.addAllowedApplication(pkg) } catch (_: Exception) {}
                }
                Log.i(TAG, "Per-app: ${extras.perAppList.size} allowed apps")
            }
            "disallowed" -> {
                for (pkg in extras.perAppList) {
                    try { builder.addDisallowedApplication(pkg) } catch (_: Exception) {}
                }
                Log.i(TAG, "Per-app: ${extras.perAppList.size} excluded apps")
            }
        }

        // Bail if a newer start/stop has been issued while we were setting up.
        if (tunnelGeneration.get() != generation) {
            Log.i(TAG, "startTunnel: superseded by generation ${tunnelGeneration.get()} (mine=$generation), aborting")
            return
        }

        // Close any previous VPN interface before creating a replacement.
        // Android restores default routes when the TUN fd is closed; leaving
        // an old one open leaks the fd and may leave stale routes that block
        // internet after disconnect (the "broken VPN, no internet" state).
        val oldIface = synchronized(ifaceLock) { vpnInterface.also { vpnInterface = null } }
        if (oldIface != null) {
            // Stop the old core before pulling its TUN: a core that loses its fd
            // reports an error, and that frame would land after this start began.
            synchronized(nativeLock) { nativeStop() }
            runCatching { oldIface.close() }
            VpnStateManager.resetStatus()
        }
        currentServerAddr = null

        // Слишком длинная таблица маршрутов не влезает в Binder-транзакцию и
        // раньше валила процесс целиком (TransactionTooLargeException).
        val iface = try {
            builder.establish()
        } catch (e: Exception) {
            Log.e(TAG, "establish() failed", e)
            null
        }
        if (iface == null) {
            mainHandler.post { failTunnel("Не удалось создать TUN", generation) }
            return
        }
        // Disconnect tapped while establish() ran — the new TUN must not survive it.
        synchronized(ifaceLock) {
            if (tunnelGeneration.get() != generation) {
                runCatching { iface.close() }
                return
            }
            vpnInterface = iface
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            VpnStateManager.systemAlwaysOn.value = isAlwaysOn to isLockdownEnabled
        }
        // The TUN is up from here on and blocks traffic until the core
        // connects — and keeps blocking it while the core reconnects. Only
        // Disconnect, onRevoke or a fatal error take it down.

        val params = TunnelParams(
            serverName = extras.serverName,
            serverAddr = extras.serverAddr,
            connString = extras.connString,
            relayAddr = extras.relayAddr,
        )
        savedParams = params
        if (extras.relayAddr.isNotBlank()) {
            VpnStateManager.emitLifecycleLog("INFO", "Relay: ${effectiveHostPort(params)}")
        }

        val serverAddr = awaitServerAddr(effectiveHostPort(params), generation) ?: return
        if (!startNative(params, serverAddr, generation)) return

        if (tunnelGeneration.get() != generation) return
        // v0.27.0 (W8): acquire PARTIAL_WAKE_LOCK now that the tunnel is up.
        // Released in stopTunnelAsync (clean stop) and onDestroy (safety net).
        // Without this Samsung One UI 7 throttles CPU scheduling for our
        // backgrounded foreground service when the screen locks, starving
        // the Rust telemetry / TLS-read loops and timing out apps' TCP
        // sessions through the VPN within minutes.
        acquireTunnelWakeLock()

        // Is name resolution actually working through the tunnel? Stream count and
        // byte counters cannot answer that — see DnsHealthMonitor for the incident
        // where 6.8 MB/s flowed while nothing resolved and the UI stayed green.
        DnsHealthMonitor.start(this, extras.serverName, dnsServers)
        // Connecting → Connected happens when the core reports state=connected
        // (syncLifecycleStateFromStatusFrame).
    }

    /** Full tunnel minus LAN / link-local / multicast — see [fullTunnelRoutes]. */
    private fun addFullTunnelRoutes(builder: Builder) {
        for ((addr, prefix) in fullTunnelRoutes()) builder.addRoute(addr, prefix)
    }

    /**
     * Starts the core on the current TUN. Returns false when the start was
     * cancelled (newer generation) or failed — failTunnel is already posted then.
     */
    private fun startNative(params: TunnelParams, serverAddr: String, generation: Int): Boolean {
        val cfgJson = buildConnectProfileJson(params.serverName, params.connString, serverAddr)
        val result = synchronized(nativeLock) {
            val iface = vpnInterface
            if (tunnelGeneration.get() != generation || iface == null) return false
            nativeStart(iface.fd, cfgJson, this)
        }
        if (result != 0) {
            mainHandler.post { failTunnel(nativeStartErrorMessage(result), generation) }
            return false
        }
        currentServerAddr = serverAddr
        return true
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
     * Build a ConnectProfile JSON string suitable for nativeStart's cfgJson parameter.
     * The conn_string must be a valid ghs:// URL. If blank, Rust will return an error.
     *
     * [serverAddr] is the pre-resolved IP:port from [resolveServerAddr].
     * We patch the authority in conn_string so Rust never resolves a name
     * itself (the VPN TUN is already active, DNS would be circular).
     */
    private fun buildConnectProfileJson(
        name: String,
        connString: String,
        serverAddr: String,
    ): String {
        val effectiveConnString = patchConnStringAuthority(connString, serverAddr)
        // The Rust side reads TunnelSettings from `ConnectProfile.settings`.
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
        -1 -> "Повреждена строка подключения — импортируйте профиль заново"
        -2 -> "Адрес сервера не определён"
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
        tunnelGeneration.incrementAndGet() // Invalidate any in-flight startTunnel threads
        // Clear the DNS indicator immediately — a stale "DNS ok" next to a
        // torn-down tunnel is exactly the kind of lie this monitor exists to stop.
        DnsHealthMonitor.stop()
        // v0.27.0 (W8): release the tunnel wake lock as soon as we're tearing
        // down. No reason to keep CPU pinned through the 1500 ms cooldown +
        // nativeStop teardown — those don't need real-time scheduling.
        releaseTunnelWakeLock()
        currentServerAddr = null
        savedParams = null
        lastWidgetState = null
        val ctx = applicationContext
        persistScope.launch { WidgetState.push(context = ctx, connected = false) }
        startupThread?.interrupt()
        startupThread = null
        if (finalState !is VpnState.Error) {
            mainHandler.post { VpnStateManager.update(VpnState.Disconnecting) }
        }

        // КРИТИЧНО: закрываем tun fd ДО nativeStop. Это заставляет все native
        // read/write на tun получить EBADF и мгновенно разблокирует любой
        // зависший nativeStart/tun-io loop. Без этого при disconnect во время
        // реконнекта сервис продолжает держать tun-интерфейс (иконка ключа в
        // статус-баре остаётся, интернета нет) пока не отработает 3-секундный
        // watchdog на nativeStop.
        val iface = synchronized(ifaceLock) { vpnInterface.also { vpnInterface = null } }
        runCatching { iface?.close() }

        Thread {
            val nativeStopDone = Thread {
                runCatching { synchronized(nativeLock) { nativeStop() } }
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
                // The next session starts from a clean frame, not from this
                // one's reconnect counter.
                VpnStateManager.resetStatus()
                VpnStateManager.update(finalState)
                val nm = getSystemService(NotificationManager::class.java)
                nm?.cancel(ALERT_NOTIFICATION_ID)
                nm?.cancel(CAPTIVE_NOTIFICATION_ID)
                captiveHintShown = false
                // A fatal error drops the TUN, and traffic goes around the VPN
                // from now on — say so even if the app isn't open.
                if (finalState is VpnState.Error) {
                    notifyAlert(ALERT_NOTIFICATION_ID, "VPN отключён", finalState.message)
                }
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

    /** Fatal error: show [message] and take the tunnel down. Ignored if a newer
     *  start/stop superseded [generation] or a stop is already running. */
    private fun failTunnel(message: String, generation: Int = tunnelGeneration.get()) {
        if (generation != tunnelGeneration.get() || teardownInProgress) return
        persistScope.launch { runCatching { prefs.setWasRunning(false) } }
        stopTunnelAsync(VpnState.Error(message))
    }

    override fun onRevoke() {
        // Not on serviceScope: onDestroy cancels it milliseconds later and the
        // write would never land — BootReceiver would then resurrect a VPN the
        // user just handed to another app.
        persistScope.launch { runCatching { prefs.setWasRunning(false) } }
        stopTunnelAsync()
        super.onRevoke()
    }

    /**
     * Склеивает соседние туннельные маршруты, проглатывая дырки ≤ maxGap адресов,
     * пока таблица не уложится в [budget]. Проглоченная дырка — российская подсеть,
     * которая поедет через выход вместо direct; НИ ОДИН не-российский адрес при
     * этом не покидает туннель, поэтому инвариант dd94139b соблюдён.
     *
     * После склейки заново вырезаем приватные/link-local/multicast: широкий порог
     * может их накрыть, а датапас такие пакеты не доставит (отвалился бы LAN).
     */
    private fun mergeSmallGaps(arr: JSONArray, budget: Int): List<Pair<String, Int>> {
        data class R(val start: Long, val end: Long)
        val nets = ArrayList<R>(arr.length())
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            val base = ipToLong(o.getString("addr")) ?: continue
            val prefix = o.getInt("prefix").coerceIn(0, 32)
            val size = 1L shl (32 - prefix)
            nets.add(R(base, base + size - 1))
        }
        if (nets.isEmpty()) return emptyList()
        nets.sortBy { it.start }

        var gap = GAP_MERGE_START
        var result: List<Pair<String, Int>> = emptyList()
        for (attempt in 0 until 8) {
            val ranges = ArrayList<R>()
            var cs = nets[0].start
            var ce = nets[0].end
            for (k in 1 until nets.size) {
                val n = nets[k]
                when {
                    n.start <= ce + 1 -> ce = maxOf(ce, n.end)          // смежно/перекрытие
                    n.start - ce - 1 <= gap -> ce = maxOf(ce, n.end)    // мелкая дырка — глотаем
                    else -> { ranges.add(R(cs, ce)); cs = n.start; ce = n.end }
                }
            }
            ranges.add(R(cs, ce))

            val out = ArrayList<Pair<String, Int>>()
            for (r in ranges) {
                for (piece in rangeToPrefixes(r.start, r.end)) {
                    out.addAll(carveSpecials(piece.first, piece.second))
                }
            }
            result = out
            if (out.size <= budget) {
                Log.i(TAG, "Route merge: gap<=$gap → ${out.size} routes")
                return out
            }
            gap = gap * 2 + 1
        }
        Log.w(TAG, "Route merge hit attempt limit, ${result.size} routes")
        return result
    }

    /**
     * Читает direct-список и отдаёт префиксы для excludeRoute(): сами российские
     * подсети плюс приватные диапазоны, чтобы LAN остался доступен.
     *
     * Точный список влезает в бюджет целиком — склейка нужна только если стран
     * выбрано много. Склейка здесь выталкивает чужие адреса из туннеля (обратная
     * сторона dd94139b), поэтому порог растёт минимально и пишется в лог.
     *
     * Пустой результат — список непригоден, вызывающий включает полный туннель.
     */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun loadExcludePrefixes(path: String, budget: Int): List<IpPrefix> {
        val nets = ArrayList<Pair<Long, Long>>()
        var tooWide = false
        try {
            File(path).forEachLine { line ->
                val s = line.trim()
                if (s.isEmpty() || s.startsWith("#") || ':' in s) return@forEachLine
                val slash = s.indexOf('/')
                val base = ipToLong(if (slash < 0) s else s.substring(0, slash)) ?: return@forEachLine
                val prefix = (if (slash < 0) 32 else s.substring(slash + 1).toIntOrNull() ?: return@forEachLine)
                    .coerceIn(0, 32)
                if (prefix < 8) tooWide = true
                val size = 1L shl (32 - prefix)
                val aligned = base and (0xFFFFFFFFL - size + 1)
                nets.add(aligned to aligned + size - 1)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to read direct list $path", e)
            return emptyList()
        }
        // Тот же fail-open, что закрыт в ADR 0016 для пути с комплементом:
        // префикс короче /8 в direct-списке выводит из туннеля огромный кусок
        // интернета (0.0.0.0/0 — весь). Такой список не применяем.
        if (tooWide) {
            Log.w(TAG, "Direct list has a prefix wider than /8 — ignoring it")
            return emptyList()
        }
        // 127/8 VpnService исключать не даёт («Bad address»), да и в туннель
        // loopback всё равно не уходит — ядро отдаёт его на lo.
        for ((s, e) in SPECIAL_RANGES) if (s != 0x7F000000L) nets.add(s to e)
        if (nets.isEmpty()) return emptyList()
        nets.sortBy { it.first }

        // Сначала мягкая склейка с жёстким потолком: разрыв до EXCLUDE_MAX_GAP
        // адресов проглатывается, и ровно столько чужих адресов может уйти мимо
        // туннеля. Потолок фиксирован, поэтому утечка ограничена ~1,5 млн адресов
        // на geoip ru — в отличие от растущего порога, который отдавал наружу
        // десятки миллионов.
        var prefixes = collapseToPrefixes(nets, 0L)
        if (prefixes.size > budget) {
            prefixes = collapseToPrefixes(nets, EXCLUDE_MAX_GAP)
        }
        // Если и этого мало — выкидываем самые мелкие блоки. Выкинутый блок
        // едет через туннель: медленнее, но безопасно. Расширять склейку дальше
        // нельзя — это выталкивало бы чужие адреса наружу (инвариант dd94139b).
        val dropped = prefixes.size - budget
        if (dropped > 0) {
            prefixes = prefixes.sortedByDescending { 1L shl (32 - it.prefixLength) }.take(budget)
            Log.w(TAG, "Exclude list trimmed to $budget prefixes ($dropped smallest dropped to tunnel)")
        } else {
            Log.i(TAG, "Exclude list: ${prefixes.size} prefixes")
        }
        return prefixes
    }

    /** Склеивает диапазоны, проглатывая разрывы ≤ [gap], и режет результат на CIDR. */
    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun collapseToPrefixes(nets: List<Pair<Long, Long>>, gap: Long): List<IpPrefix> {
        val out = ArrayList<IpPrefix>()
        var cs = nets[0].first
        var ce = nets[0].second
        fun flush() {
            for ((p, l) in rangeToPrefixes(cs, ce)) {
                out.add(IpPrefix(InetAddress.getByName(longToIp(p)), l))
            }
        }
        for (k in 1 until nets.size) {
            val (s, e) = nets[k]
            if (s <= ce + 1 || s - ce - 1 <= gap) ce = maxOf(ce, e)
            else { flush(); cs = s; ce = e }
        }
        flush()
        return out
    }

    override fun onDestroy() {
        unregisterNetworkCallback()
        // A regular stop is already under way and will settle the state itself;
        // a second stop here would wipe a shown error. Otherwise the system is
        // removing us — drop the tunnel quietly.
        if (!teardownInProgress) quietCleanup()
        // v0.27.0 (W8): safety net — stopTunnelAsync already releases on every
        // user-/system-initiated stop, but onDestroy can also fire from system
        // resource pressure with the lock still held. Double-release is safe:
        // releaseTunnelWakeLock() null-checks and isHeld-checks internally.
        releaseTunnelWakeLock()
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun quietCleanup() {
        tunnelGeneration.incrementAndGet()
        startupThread?.interrupt()
        DnsHealthMonitor.stop()
        val iface = synchronized(ifaceLock) { vpnInterface.also { vpnInterface = null } } ?: return
        runCatching { iface.close() }
        Thread { runCatching { synchronized(nativeLock) { nativeStop() } } }
            .apply { name = "vpn-native-stop"; isDaemon = true; start() }
        VpnStateManager.resetStatus()
        VpnStateManager.update(VpnState.Disconnected)
    }

    private fun startForegroundCompat(content: Triple<String, String, Int>) {
        val n = buildNotification(content)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, n, FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
    }

    // ── Physical networks ──────────────────────────────────────────────────
    private fun registerNetworkCallback() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        connectivityManager = cm
        val req = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            // Since API 26 onAvailable is always followed by onCapabilitiesChanged.
            override fun onCapabilitiesChanged(n: Network, caps: NetworkCapabilities) {
                val validated = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                val wasValidated = physicalNetworks.put(n, caps)
                    ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
                onPhysicalNetworksChanged()
                if (validated && !wasValidated) reresolve(n)
            }
            override fun onLost(n: Network) {
                physicalNetworks.remove(n)
                onPhysicalNetworksChanged()
            }
        }
        networkCallback = cb
        // The system default network is followed on its own: we never call
        // setUnderlyingNetworks, which is the same as passing null.
        runCatching { cm.registerNetworkCallback(req, cb) }
            .onFailure { Log.w(TAG, "registerNetworkCallback failed", it) }
    }

    private fun unregisterNetworkCallback() {
        val cm = connectivityManager ?: return
        val cb = networkCallback ?: return
        runCatching { cm.unregisterNetworkCallback(cb) }
        networkCallback = null
    }

    private fun onPhysicalNetworksChanged() {
        synchronized(networkLock) { networkLock.notifyAll() }
        updateCaptivePortalHint()
    }

    private fun validatedNetwork(): Network? = physicalNetworks.entries
        .firstOrNull { it.value.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) }?.key

    /** Where TCP goes: the relay (SNI stays the exit's — passthrough) or the exit itself. */
    private fun effectiveHostPort(p: TunnelParams): String = when {
        p.relayAddr.isBlank() -> p.serverAddr
        p.relayAddr.contains(':') -> p.relayAddr
        else -> "${p.relayAddr}:${p.serverAddr.substringAfterLast(':', "443")}"
    }

    /**
     * host:port → ip:port, resolved through a physical network: DNS through the
     * TUN can't work (the core isn't up). A VALIDATED network is preferred.
     * Some never validate (mobile whitelists, a blocked connectivity check), so
     * any other will do — except a captive portal, whose resolver hands back the
     * portal. Only a validated answer is remembered; a network that validates
     * later re-checks the address ([reresolve]). Lookup failed → the last good
     * address of this host. null — nothing to go on yet. A name never reaches
     * Rust: there it would be resolved through the dead TUN.
     */
    private fun resolveServerAddr(hostPort: String): String? {
        val (host, port) = splitHostPort(hostPort)
        if (isIpLiteral(host)) return hostPort

        val validated = validatedNetwork()
        val net = validated ?: physicalNetworks.entries.firstOrNull {
            !it.value.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)
        }?.key
        val fresh = net?.let { lookup(it, host)?.first() }
        val ip = if (fresh != null) {
            if (validated != null) resolvedCache[host] = fresh
            fresh
        } else {
            resolvedCache[host]?.also {
                VpnStateManager.emitLifecycleLog("INFO", "DNS: $host — последний известный адрес $it")
            } ?: return null
        }
        return joinHostPort(ip, port)
    }

    /** All addresses of [host] through [net], IPv4 first; null — lookup failed. */
    private fun lookup(net: Network, host: String): List<String>? = runCatching {
        // v0.25.0: prefer IPv4 explicit — наши серверы v4-only, на
        // IPv6-only сетях (T-Mobile US, Иран) первый возвращённый адрес
        // может быть IPv6 → TCP connect timeout. Bug #9.
        net.getAllByName(host).sortedBy { it !is Inet4Address }.mapNotNull { it.hostAddress }
    }.onFailure {
        Log.w(TAG, "DNS resolution failed for $host: ${it.message}")
        VpnStateManager.emitLifecycleLog("WARN", "DNS: не удалось разрешить $host — ${it.message}")
    }.getOrNull()?.takeIf { it.isNotEmpty() }?.also {
        VpnStateManager.emitLifecycleLog("DEBUG", "DNS: $host → ${it.joinToString()}")
    }

    private fun splitHostPort(hostPort: String): Pair<String, String> {
        val lastColon = hostPort.lastIndexOf(':')
        return if (lastColon > 0) hostPort.substring(0, lastColon) to hostPort.substring(lastColon + 1)
        else hostPort to "443"
    }

    private fun isIpLiteral(host: String) = ipToLong(host) != null || host.contains(':')

    private fun joinHostPort(ip: String, port: String) = if (ip.contains(':')) "[$ip]:$port" else "$ip:$port"

    /** Blocks until the server address is known (see [resolveServerAddr]).
     *  null — the start was cancelled meanwhile. */
    private fun awaitServerAddr(hostPort: String, generation: Int): String? {
        var announced = false
        while (tunnelGeneration.get() == generation) {
            resolveServerAddr(hostPort)?.let { return it }
            if (!announced) {
                announced = true
                VpnStateManager.emitLifecycleLog("WARN", "Не удалось узнать адрес сервера — жду сеть")
            }
            try {
                synchronized(networkLock) { networkLock.wait(10_000L) }
            } catch (_: InterruptedException) {
                return null
            }
        }
        return null
    }

    /**
     * The server name may point elsewhere now: [net] just got VALIDATED, or the
     * link has been down for a while (the relay may have moved). Resolved
     * through the validated [net]; the core is restarted only if its address is
     * not among the answers. Reconnecting after a network change as such is the
     * core's job.
     */
    private fun reresolve(net: Network) {
        val params = savedParams ?: return
        val current = currentServerAddr ?: return
        val generation = tunnelGeneration.get()
        Thread {
            val (host, port) = splitHostPort(effectiveHostPort(params))
            if (isIpLiteral(host)) return@Thread
            val addrs = lookup(net, host) ?: return@Thread
            resolvedCache[host] = addrs.first()
            if (addrs.any { joinHostPort(it, port) == current } || currentServerAddr != current) return@Thread
            val fresh = joinHostPort(addrs.first(), port)
            Log.i(TAG, "Server address changed: $current → $fresh")
            VpnStateManager.emitLifecycleLog("INFO", "Адрес сервера сменился ($current → $fresh), перезапуск")
            // A new core starts from scratch — the UI must not keep the old "Connected".
            VpnStateManager.resetStatus()
            mainHandler.post {
                if (tunnelGeneration.get() == generation) VpnStateManager.update(VpnState.Connecting)
            }
            startNative(params, fresh, generation)
        }.apply { name = "vpn-reresolve"; isDaemon = true; start() }
    }

    /**
     * Wi-Fi behind a captive portal and no validated network at all: the tunnel
     * can't come up until the user signs in. The system sign-in window bypasses
     * the VPN; once the network is VALIDATED the core connects on its own.
     */
    private fun updateCaptivePortalHint() {
        val captive = validatedNetwork() == null && physicalNetworks.values.any {
            it.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL)
        }
        if (captive == captiveHintShown) return
        captiveHintShown = captive
        if (captive) {
            val wifiSettings = PendingIntent.getActivity(
                this, 1,
                Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            notifyAlert(
                CAPTIVE_NOTIFICATION_ID, "Wi-Fi требует входа",
                "Войдите в сеть через системное уведомление или настройки Wi-Fi — VPN подключится сам.",
                wifiSettings,
            )
        } else {
            getSystemService(NotificationManager::class.java)?.cancel(CAPTIVE_NOTIFICATION_ID)
        }
    }

    // ── Notifications ──────────────────────────────────────────────────────
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

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        packageManager.getLaunchIntentForPackage(packageName) ?: Intent(),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** One-shot alert on the DEFAULT-importance channel. */
    private fun notifyAlert(id: Int, title: String, text: String, tap: PendingIntent = openAppIntent()) {
        val nm = getSystemService(NotificationManager::class.java) ?: return
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, ALERT_CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        val n = builder
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setSmallIcon(R.drawable.ic_notification)
            .setAutoCancel(true)
            .setContentIntent(tap)
            .build()
        runCatching { nm.notify(id, n) }
            .onFailure { Log.w(TAG, "notify($id) failed", it) }
    }

    /**
     * Keeps the ongoing notification honest. It is rebuilt only when what it
     * shows changes (state kind, or k/n while degraded) — no per-frame churn,
     * no live numbers that freeze anyway. A short drop (network handoff) stays
     * quiet; only after NO_LINK_ALERT_DELAY_MS without a link it turns into
     * "Нет связи" and, if the tunnel had been up, raises one heads-up alert.
     *
     * This only REFLECTS health — reconnecting is the Rust core's job.
     */
    private fun startNotificationCollector() {
        serviceScope.launch {
            var wasUp = false
            combine(VpnStateManager.derivedVpnState, VpnStateManager.statusFrame) { state, frame ->
                state to degradedStreams(frame)
            }
                .distinctUntilChanged { a, b -> a.first::class == b.first::class && a.second == b.second }
                .collectLatest { (state, degraded) ->
                    // Don't resurrect a notification once the tunnel is gone — the
                    // teardown path calls stopForeground(REMOVE) itself, and for an
                    // error it posts the reason as an alert.
                    if (state is VpnState.Disconnected || state is VpnState.Disconnecting ||
                        state is VpnState.Error
                    ) {
                        wasUp = false
                        return@collectLatest
                    }
                    val nm = getSystemService(NotificationManager::class.java) ?: return@collectLatest
                    if (state is VpnState.Connected || state is VpnState.Stale || state is VpnState.Throttled) {
                        wasUp = true
                        nm.cancel(ALERT_NOTIFICATION_ID)
                    }
                    nm.notify(NOTIFICATION_ID, buildNotification(notificationContentFor(state, degraded)))
                    if (state is VpnState.Reconnecting || state is VpnState.Connecting) {
                        delay(NO_LINK_ALERT_DELAY_MS)
                        // A stable network never re-validates — check here whether
                        // the server name has moved away from the address the core
                        // keeps retrying.
                        validatedNetwork()?.let { reresolve(it) }
                        nm.notify(
                            NOTIFICATION_ID,
                            buildNotification(Triple(
                                "Нет связи",
                                "Трафик заблокирован до восстановления связи. «Отключить» — выйти без VPN.",
                                0xFFE05A4A.toInt(),
                            )),
                        )
                        if (wasUp) {
                            wasUp = false
                            notifyAlert(
                                ALERT_NOTIFICATION_ID, "VPN: нет связи",
                                "Связи нет дольше 25 с. Трафик заблокирован, переподключение идёт само.",
                            )
                        }
                    }
                }
        }
    }

    /** "k/n" when streams died but the bandwidth isn't throttled; null otherwise. */
    private fun degradedStreams(frame: StatusFrameData): String? =
        if (frame.health == TunnelHealth.DEGRADED && frame.bandwidthClass != BandwidthClass.THROTTLED) {
            "${frame.streamsUp}/${frame.nStreams}"
        } else null

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

    /** Ongoing foreground notification: (title, text, accent; 0 = default). */
    private fun buildNotification(content: Triple<String, String, Int>): Notification {
        val (title, body, accent) = content
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, GhostStreamVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        builder
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            // Rebuilds must NOT buzz/alert — only the first post of a given
            // content makes a sound.
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
            .addAction(Notification.Action.Builder(null, "Отключить", stopIntent).build())
        if (accent != 0) builder.setColor(accent)
        return builder.build()
    }

    private fun statusContent(text: String) = Triple("GhostStream", text, 0)

    /** (title, text, accent) for the ongoing notification from the honest
     *  derived state. [degraded] is "k/n" from [degradedStreams]. */
    private fun notificationContentFor(state: VpnState, degraded: String? = null): Triple<String, String, Int> {
        val green = 0xFF8FE388.toInt()   // signal lime
        val amber = 0xFFE0B24A.toInt()
        val red = 0xFFE05A4A.toInt()
        return when (state) {
            is VpnState.Connected ->
                if (degraded != null) Triple("Защищено", "Деградация: $degraded стримов", amber)
                else Triple("Защищено", "Трафик идёт через туннель", green)
            is VpnState.Stale -> Triple("Канал замолчал", "Нет входящих данных, проверяю связь", amber)
            is VpnState.Throttled -> Triple("Скорость ограничена", "Сеть жива, но душит трафик", amber)
            is VpnState.Reconnecting -> Triple("Переподключение…", "Восстанавливаю соединение", amber)
            is VpnState.Connecting -> statusContent("Подключение...")
            is VpnState.Disconnecting -> statusContent("Отключение...")
            is VpnState.Error -> Triple("GhostStream", "Ошибка: ${state.message}", red)
            is VpnState.Disconnected -> statusContent("Отключено")
        }
    }
}

/** Те же диапазоны, что special_ranges() в crates/core/src/routing.rs. */
private val SPECIAL_RANGES: List<Pair<Long, Long>> = listOf(
    0x00000000L to 0x00FFFFFFL, // 0.0.0.0/8
    0x0A000000L to 0x0AFFFFFFL, // 10.0.0.0/8
    0x64400000L to 0x647FFFFFL, // 100.64.0.0/10
    0x7F000000L to 0x7FFFFFFFL, // 127.0.0.0/8
    0xA9FE0000L to 0xA9FEFFFFL, // 169.254.0.0/16
    0xAC100000L to 0xAC1FFFFFL, // 172.16.0.0/12
    0xC0A80000L to 0xC0A8FFFFL, // 192.168.0.0/16
    0xE0000000L to 0xEFFFFFFFL, // 224.0.0.0/4
    0xF0000000L to 0xFFFFFFFFL, // 240.0.0.0/4
)

/**
 * Full tunnel: all of IPv4 minus the SPECIAL_RANGES — the same carve the split
 * mode does. LAN (printer, Chromecast, router), link-local and multicast stay
 * reachable; the exit can't deliver them anyway. Our own 10.7.0.0/24 (admin
 * API) still rides the tunnel: it's the TUN's connected route, more specific
 * than the carved 10/8.
 */
internal fun fullTunnelRoutes(): List<Pair<String, Int>> = carveSpecials(0L, 0)

internal fun isSpecialAddress(ip: String): Boolean {
    val v = ipToLong(ip) ?: return false
    return SPECIAL_RANGES.any { (s, e) -> v in s..e }
}

/** Минимальный набор выровненных CIDR, точно покрывающий [start; end]. */
private fun rangeToPrefixes(start: Long, end: Long): List<Pair<Long, Int>> {
    val out = ArrayList<Pair<Long, Int>>()
    var cur = start
    while (cur <= end) {
        var len = 32 - java.lang.Long.numberOfTrailingZeros(cur).coerceAtMost(32)
        if (cur == 0L) len = 0
        while (len < 32) {
            val size = 1L shl (32 - len)
            if (cur + size - 1 <= end) break
            len++
        }
        out.add(cur to len)
        val last = cur + (1L shl (32 - len)) - 1
        if (last >= end || last == 0xFFFFFFFFL) break
        cur = last + 1
    }
    return out
}

/** Вырезает из блока спец-диапазоны, возвращая куски в виде "addr"/prefix. */
private fun carveSpecials(base: Long, prefix: Int): List<Pair<String, Int>> {
    val size = 1L shl (32 - prefix)
    var pieces = listOf(base to base + size - 1)
    for ((sStart, sEnd) in SPECIAL_RANGES) {
        val next = ArrayList<Pair<Long, Long>>()
        for ((a, b) in pieces) {
            if (sEnd < a || sStart > b) { next.add(a to b); continue }
            if (sStart > a) next.add(a to sStart - 1)
            if (sEnd < b) next.add(sEnd + 1 to b)
        }
        pieces = next
    }
    val out = ArrayList<Pair<String, Int>>()
    for ((a, b) in pieces) {
        for ((p, l) in rangeToPrefixes(a, b)) out.add(longToIp(p) to l)
    }
    return out
}

internal fun ipToLong(s: String): Long? {
    val parts = s.split('.')
    if (parts.size != 4) return null
    var v = 0L
    for (p in parts) {
        val b = p.toIntOrNull() ?: return null
        if (b !in 0..255) return null
        v = (v shl 8) or b.toLong()
    }
    return v
}

private fun longToIp(v: Long): String =
    "${(v shr 24) and 0xFF}.${(v shr 16) and 0xFF}.${(v shr 8) and 0xFF}.${v and 0xFF}"
