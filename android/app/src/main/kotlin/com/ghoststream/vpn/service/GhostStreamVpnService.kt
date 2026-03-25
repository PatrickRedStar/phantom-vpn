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

class GhostStreamVpnService : VpnService() {

    private data class TunnelParams(
        val serverAddr: String,
        val serverName: String,
        val insecure: Boolean,
        val certPath: String,
        val keyPath: String,
        val caCertPath: String,
    )

    private var vpnInterface: ParcelFileDescriptor? = null
    private var watchdogThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var savedParams: TunnelParams? = null
    @Volatile private var userStopped = false

    // Instance method so JNI receives the service object for VpnService.protect()
    external fun nativeStart(
        tunFd: Int,
        serverAddr: String,
        serverName: String,
        insecure: Boolean,
        certPath: String,
        keyPath: String,
        caCertPath: String,
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

        private const val CHANNEL_ID      = "ghoststream_vpn"
        private const val NOTIFICATION_ID  = 1001
        private const val TAG = "GhostStreamVpn"
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

        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID, buildNotification("Подключение..."),
                FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Подключение..."))
        }

        startTunnel(
            serverAddr, serverName, insecure, certPath, keyPath, caCertPath,
            tunAddr, dnsServers, splitRouting, directCidrs, perAppMode, perAppList,
        )
        return START_STICKY
    }

    private fun startTunnel(
        serverAddr: String, serverName: String,
        insecure: Boolean, certPath: String, keyPath: String, caCertPath: String,
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
        savedParams = TunnelParams(serverAddr, serverName, insecure, certPath, keyPath, caCertPath)

        val fd = vpnInterface!!.fd
        val result = nativeStart(fd, serverAddr, serverName, insecure, certPath, keyPath, caCertPath)
        if (result != 0) {
            vpnInterface?.close()
            vpnInterface = null
            VpnStateManager.update(VpnState.Error("Ошибка запуска туннеля"))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        // Do NOT set Connected here — watchdog will do it once QUIC handshake completes
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
            outer@ while (!Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    break
                }
                try {
                    val stats = nativeGetStats() ?: continue
                    val connected = stats.contains("\"connected\":true")
                    if (connected && !wasConnected) {
                        wasConnected = true
                        timeoutSecs = Int.MAX_VALUE
                        mainHandler.post {
                            VpnStateManager.update(VpnState.Connected(serverName = serverName))
                            val nm = getSystemService(NotificationManager::class.java)
                            nm?.notify(NOTIFICATION_ID, buildNotification("Подключено: $serverAddr"))
                        }
                    }
                    if (!connected && wasConnected) {
                        wasConnected = false
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
                            val params = savedParams ?: break@outer
                            val iface = vpnInterface ?: break@outer
                            nativeStop()
                            val r = nativeStart(
                                iface.fd, params.serverAddr, params.serverName,
                                params.insecure, params.certPath, params.keyPath, params.caCertPath,
                            )
                            if (r == 0) {
                                timeoutSecs = 60
                                reconnected = true
                                break
                            }
                            backoffMs = minOf(backoffMs * 2, 60_000L)
                        }
                        if (!reconnected) {
                            mainHandler.post { failTunnel("Не удалось переподключиться к серверу") }
                            break@outer
                        }
                        continue@outer
                    }
                    timeoutSecs--
                    if (!connected && timeoutSecs <= 0) {
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

    private fun stopTunnel() {
        userStopped = true
        watchdogThread?.interrupt()
        watchdogThread = null
        nativeStop()
        vpnInterface?.close()
        vpnInterface = null
        VpnStateManager.update(VpnState.Disconnected)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun failTunnel(message: String) {
        userStopped = true
        watchdogThread?.interrupt()
        watchdogThread = null
        nativeStop()
        vpnInterface?.close()
        vpnInterface = null
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
