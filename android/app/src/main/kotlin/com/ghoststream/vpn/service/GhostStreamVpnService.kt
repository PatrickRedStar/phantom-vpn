package com.ghoststream.vpn.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import com.ghoststream.vpn.R
import org.json.JSONArray
import org.json.JSONObject

class GhostStreamVpnService : VpnService() {

    private data class TunnelParams(
        val serverAddr: String,
        val serverName: String,
        val insecure: Boolean,
        val certPath: String,
        val keyPath: String,
        val caCertPath: String,
        val requestedTransport: String,
    )

    private data class NativeStatsSnapshot(
        val bytesRx: Long,
        val bytesTx: Long,
        val connected: Boolean,
        val capturedAtMs: Long,
    )

    private var vpnInterface: ParcelFileDescriptor? = null
    private var watchdogThread: Thread? = null
    private var startupThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var savedParams: TunnelParams? = null
    @Volatile private var userStopped = false
    @Volatile private var runtimeTransport = "h2"
    @Volatile private var autoFallbackCount = 0
    @Volatile private var lastAutoFallbackAtMs = 0L
    @Volatile private var nextAutoQuicRetryAtMs = 0L

    // Instance method so JNI receives the service object for VpnService.protect()
    external fun nativeStart(
        tunFd: Int,
        serverAddr: String,
        serverName: String,
        insecure: Boolean,
        certPath: String,
        keyPath: String,
        caCertPath: String,
        transport: String,
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
        const val EXTRA_CA_CERT_PATH  = "ca_cert_path"
        const val EXTRA_TRANSPORT     = "transport"

        private const val CHANNEL_ID      = "ghoststream_vpn"
        private const val NOTIFICATION_ID  = 1001
        private const val TAG = "GhostStreamVpn"
        private const val AUTO_PROBE_WINDOW_MS = 5_000L
        private const val AUTO_RECHECK_INTERVAL_MS = 15 * 60_000L
        private const val AUTO_FALLBACK_WINDOW_MS = 30 * 60_000L
        private const val AUTO_MAX_FALLBACKS = 2
        private const val AUTO_MIN_GOOD_Mbps = 100.0
        private const val AUTO_STRONG_DIRECTION_Mbps = 150.0
        private const val AUTO_MIN_TOTAL_BYTES = 16L * 1024 * 1024
        private const val AUTO_MIN_DIRECTION_BYTES = 4L * 1024 * 1024
        // Safety cap: too many addRoute() entries can overflow Binder transaction
        // in VpnService.Builder.establish() and crash with TransactionTooLargeException.
        private const val MAX_SPLIT_ROUTES = 8000
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopTunnel()
            return START_NOT_STICKY
        }

        val serverAddr = intent?.getStringExtra(EXTRA_SERVER_ADDR) ?: return START_NOT_STICKY
        val serverName = intent.getStringExtra(EXTRA_SERVER_NAME)
            ?: serverAddr.substringBefore(":")
        val insecure   = intent.getBooleanExtra(EXTRA_INSECURE, false)
        val certPath   = intent.getStringExtra(EXTRA_CERT_PATH) ?: ""
        val keyPath    = intent.getStringExtra(EXTRA_KEY_PATH)  ?: ""
        val tunAddr    = intent.getStringExtra(EXTRA_TUN_ADDR)  ?: "10.7.0.2/24"
        val dnsServers = (intent.getStringExtra(EXTRA_DNS_SERVERS) ?: "8.8.8.8,1.1.1.1")
            .split(",").filter { it.isNotBlank() }
        val splitRouting   = intent.getBooleanExtra(EXTRA_SPLIT_ROUTING, false)
        val directCidrs    = intent.getStringExtra(EXTRA_DIRECT_CIDRS) ?: ""
        val perAppMode     = intent.getStringExtra(EXTRA_PER_APP_MODE) ?: "none"
        val perAppList     = (intent.getStringExtra(EXTRA_PER_APP_LIST) ?: "")
            .split(",").filter { it.isNotBlank() }
        val caCertPath     = intent.getStringExtra(EXTRA_CA_CERT_PATH) ?: ""
        val transport      = normalizeTransport(intent.getStringExtra(EXTRA_TRANSPORT))

        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID, buildNotification("Подключение..."),
                FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Подключение..."))
        }

        startupThread?.interrupt()
        startupThread = Thread {
            startTunnel(
                serverAddr, serverName, insecure, certPath, keyPath, caCertPath, transport,
                tunAddr, dnsServers, splitRouting, directCidrs, perAppMode, perAppList,
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
        insecure: Boolean, certPath: String, keyPath: String, caCertPath: String,
        transport: String,
        tunAddr: String, dnsServers: List<String>,
        splitRouting: Boolean, directCidrsPath: String,
        perAppMode: String, perAppList: List<String>,
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

        vpnInterface = builder.establish() ?: run {
            VpnStateManager.update(VpnState.Error("Не удалось создать TUN"))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        userStopped = false
        savedParams = TunnelParams(
            serverAddr = serverAddr,
            serverName = serverName,
            insecure = insecure,
            certPath = certPath,
            keyPath = keyPath,
            caCertPath = caCertPath,
            requestedTransport = transport,
        )
        runtimeTransport = resolveInitialTransport(transport)
        resetAutoRuntimeState()

        val fd = vpnInterface!!.fd
        val result = nativeStart(
            fd, serverAddr, serverName, insecure, certPath, keyPath, caCertPath, runtimeTransport,
        )
        if (result != 0) {
            vpnInterface?.close()
            vpnInterface = null
            VpnStateManager.update(VpnState.Error("Ошибка запуска туннеля"))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        // Set Connected immediately so Android starts routing traffic through VPN
        // Watchdog will monitor connection health
        val notification = buildNotification("Подключение...")
        startForeground(1, notification)
        VpnStateManager.update(VpnState.Connecting)

        startWatchdog(serverName, serverAddr)
    }

    /**
     * Monitors native tunnel state and drives VpnState transitions:
     * - Connecting → Connected when QUIC handshake succeeds (IS_CONNECTED=true)
     * - Connected → Connecting + auto-reconnect (exponential backoff) if tunnel drops
     * - Connecting → Error after 60s timeout if handshake never completes
     */
    private fun startWatchdog(serverName: String, serverAddr: String) {
        watchdogThread?.interrupt()
        watchdogThread = Thread {
            var wasConnected = false
            var timeoutSecs = 60
            var connectedAtMs = 0L
            var quicProbeStart: NativeStatsSnapshot? = null
            outer@ while (!Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    break
                }
                try {
                    val params = savedParams ?: continue
                    val stats = readNativeStats() ?: continue
                    val connected = stats.connected
                    val nowMs = stats.capturedAtMs
                    if (connected && !wasConnected) {
                        wasConnected = true
                        timeoutSecs = Int.MAX_VALUE
                        connectedAtMs = nowMs
                        quicProbeStart = if (params.requestedTransport == "auto" && runtimeTransport == "quic") {
                            stats
                        } else {
                            null
                        }
                        mainHandler.post {
                            VpnStateManager.update(VpnState.Connected(serverName = serverName))
                            val nm = getSystemService(NotificationManager::class.java)
                            nm?.notify(
                                NOTIFICATION_ID,
                                buildNotification("Подключено: $serverAddr (${transportLabel(runtimeTransport)})"),
                            )
                        }
                    }
                    if (connected && wasConnected && params.requestedTransport == "auto") {
                        if (runtimeTransport == "quic") {
                            val probeStart = quicProbeStart
                            if (probeStart != null && nowMs - probeStart.capturedAtMs >= AUTO_PROBE_WINDOW_MS) {
                                quicProbeStart = null
                                if (shouldFallbackToH2(probeStart, stats)) {
                                    recordAutoFallback(nowMs)
                                    if (switchRuntimeTransport(
                                            params = params,
                                            targetTransport = "h2",
                                            restoreTransport = "quic",
                                            notification = "Переключение на HTTP/2...",
                                        )
                                    ) {
                                        wasConnected = false
                                        timeoutSecs = 60
                                        connectedAtMs = 0L
                                        continue@outer
                                    }
                                }
                            }
                        } else if (
                            runtimeTransport == "h2" &&
                            connectedAtMs > 0L &&
                            nowMs >= nextAutoQuicRetryAtMs &&
                            autoFallbackCount < AUTO_MAX_FALLBACKS &&
                            nowMs - connectedAtMs >= AUTO_RECHECK_INTERVAL_MS
                        ) {
                            nextAutoQuicRetryAtMs = nowMs + AUTO_RECHECK_INTERVAL_MS
                            if (switchRuntimeTransport(
                                    params = params,
                                    targetTransport = "quic",
                                    restoreTransport = "h2",
                                    notification = "Пробуем вернуть QUIC...",
                                )
                            ) {
                                wasConnected = false
                                timeoutSecs = 60
                                connectedAtMs = 0L
                                quicProbeStart = null
                                continue@outer
                            }
                        }
                    }
                    if (!connected && wasConnected) {
                        wasConnected = false
                        connectedAtMs = 0L
                        quicProbeStart = null
                        mainHandler.post {
                            VpnStateManager.update(VpnState.Connecting)
                            getSystemService(NotificationManager::class.java)
                                ?.notify(NOTIFICATION_ID, buildNotification("Переподключение..."))
                        }
                        // Exponential backoff: 3s, 6s, 12s, 24s, 48s, 60s, 60s, 60s
                        var backoffMs = 3_000L
                        var reconnected = false
                        for (attempt in 1..8) {
                            try { Thread.sleep(backoffMs) } catch (_: InterruptedException) { break@outer }
                            if (userStopped) break@outer
                            if (restartNativeTunnel(params, runtimeTransport)) {
                                timeoutSecs = 60
                                reconnected = true
                                break
                            }
                            backoffMs = minOf(backoffMs * 2, 60_000L)
                        }
                        if (!reconnected && params.requestedTransport == "auto" && runtimeTransport == "quic") {
                            recordAutoFallback(System.currentTimeMillis())
                            reconnected = restartNativeTunnel(params, "h2")
                            if (reconnected) {
                                timeoutSecs = 60
                                nextAutoQuicRetryAtMs = System.currentTimeMillis() + AUTO_RECHECK_INTERVAL_MS
                            }
                        }
                        if (!reconnected) {
                            mainHandler.post { failTunnel("Не удалось переподключиться к серверу") }
                            break@outer
                        }
                        continue@outer
                    }
                    timeoutSecs--
                    if (!connected && timeoutSecs <= 0) {
                        if (params.requestedTransport == "auto" && runtimeTransport == "quic") {
                            recordAutoFallback(nowMs)
                            if (restartNativeTunnel(params, "h2")) {
                                timeoutSecs = 60
                                nextAutoQuicRetryAtMs = System.currentTimeMillis() + AUTO_RECHECK_INTERVAL_MS
                                continue@outer
                            }
                        }
                        mainHandler.post {
                            VpnStateManager.update(VpnState.Error("Тайм-аут подключения к серверу"))
                            stopTunnel()
                        }
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

    private fun restartNativeTunnel(params: TunnelParams, transport: String): Boolean {
        val iface = vpnInterface ?: return false
        val targetTransport = normalizeManualTransport(transport)
        nativeStop()
        val result = nativeStart(
            iface.fd, params.serverAddr, params.serverName,
            params.insecure, params.certPath, params.keyPath, params.caCertPath,
            targetTransport,
        )
        if (result == 0) {
            runtimeTransport = targetTransport
            Log.i(TAG, "Tunnel restarted with transport=$targetTransport")
            return true
        }
        Log.w(TAG, "Tunnel restart failed for transport=$targetTransport")
        return false
    }

    private fun switchRuntimeTransport(
        params: TunnelParams,
        targetTransport: String,
        restoreTransport: String,
        notification: String,
    ): Boolean {
        mainHandler.post {
            VpnStateManager.update(VpnState.Connecting)
            getSystemService(NotificationManager::class.java)
                ?.notify(NOTIFICATION_ID, buildNotification(notification))
        }

        if (restartNativeTunnel(params, targetTransport)) {
            return true
        }

        if (restoreTransport != targetTransport) {
            restartNativeTunnel(params, restoreTransport)
        }
        return false
    }

    private fun shouldFallbackToH2(
        start: NativeStatsSnapshot,
        end: NativeStatsSnapshot,
    ): Boolean {
        val durationMs = (end.capturedAtMs - start.capturedAtMs).coerceAtLeast(1_000L)
        val rxBytes = (end.bytesRx - start.bytesRx).coerceAtLeast(0L)
        val txBytes = (end.bytesTx - start.bytesTx).coerceAtLeast(0L)
        val seconds = durationMs / 1_000.0
        val downMbps = rxBytes * 8.0 / seconds / 1_000_000.0
        val upMbps = txBytes * 8.0 / seconds / 1_000_000.0
        val minMbps = minOf(downMbps, upMbps)
        val maxMbps = maxOf(downMbps, upMbps)
        val totalBytes = rxBytes + txBytes
        val bothDirectionsActive =
            rxBytes >= AUTO_MIN_DIRECTION_BYTES && txBytes >= AUTO_MIN_DIRECTION_BYTES
        val enoughTraffic =
            totalBytes >= AUTO_MIN_TOTAL_BYTES &&
                (bothDirectionsActive || maxMbps >= AUTO_STRONG_DIRECTION_Mbps)
        val shouldFallback =
            enoughTraffic && minMbps < AUTO_MIN_GOOD_Mbps &&
                (bothDirectionsActive || maxMbps >= AUTO_STRONG_DIRECTION_Mbps)

        Log.i(
            TAG,
            "Auto probe QUIC: down=${"%.1f".format(downMbps)}Mbps up=${"%.1f".format(upMbps)}Mbps " +
                "rx=$rxBytes tx=$txBytes enoughTraffic=$enoughTraffic fallback=$shouldFallback",
        )
        return shouldFallback
    }

    private fun recordAutoFallback(nowMs: Long) {
        if (nowMs - lastAutoFallbackAtMs > AUTO_FALLBACK_WINDOW_MS) {
            autoFallbackCount = 0
        }
        autoFallbackCount += 1
        lastAutoFallbackAtMs = nowMs
        nextAutoQuicRetryAtMs = nowMs + AUTO_RECHECK_INTERVAL_MS
    }

    private fun resetAutoRuntimeState() {
        autoFallbackCount = 0
        lastAutoFallbackAtMs = 0L
        nextAutoQuicRetryAtMs = if (savedParams?.requestedTransport == "auto") {
            System.currentTimeMillis() + AUTO_RECHECK_INTERVAL_MS
        } else {
            0L
        }
    }

    private fun readNativeStats(): NativeStatsSnapshot? {
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

    private fun transportLabel(transport: String): String = when (transport) {
        "quic" -> "QUIC"
        "auto" -> "Auto"
        else -> "HTTP/2"
    }

    private fun normalizeTransport(raw: String?): String = when (raw?.trim()?.lowercase()) {
        "quic" -> "quic"
        "auto" -> "auto"
        else -> "h2"
    }

    private fun resolveInitialTransport(requestedTransport: String): String =
        if (requestedTransport == "auto") "quic" else requestedTransport

    private fun normalizeManualTransport(transport: String): String = when (transport.lowercase()) {
        "quic" -> "quic"
        else -> "h2"
    }

    private fun stopTunnel() {
        userStopped = true
        startupThread?.interrupt()
        startupThread = null
        watchdogThread?.interrupt()
        watchdogThread = null
        nativeStop()
        vpnInterface?.close()
        vpnInterface = null
        savedParams = null
        runtimeTransport = "h2"
        resetAutoRuntimeState()
        VpnStateManager.update(VpnState.Disconnected)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun failTunnel(message: String) {
        userStopped = true
        startupThread?.interrupt()
        startupThread = null
        watchdogThread?.interrupt()
        watchdogThread = null
        nativeStop()
        vpnInterface?.close()
        vpnInterface = null
        savedParams = null
        runtimeTransport = "h2"
        resetAutoRuntimeState()
        VpnStateManager.update(VpnState.Error(message))
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onRevoke() {
        stopTunnel()
        super.onRevoke()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "GhostStream VPN", NotificationManager.IMPORTANCE_LOW,
            ).apply { description = "Статус VPN-туннеля" }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
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
