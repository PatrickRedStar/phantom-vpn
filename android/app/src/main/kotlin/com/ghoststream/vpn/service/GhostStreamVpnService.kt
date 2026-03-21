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
import com.ghoststream.vpn.R

class GhostStreamVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null
    private var watchdogThread: Thread? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    // Instance method so JNI receives the service object for VpnService.protect()
    external fun nativeStart(
        tunFd: Int,
        serverAddr: String,
        serverName: String,
        insecure: Boolean,
        certPath: String,
        keyPath: String,
    ): Int

    companion object {
        init {
            System.loadLibrary("phantom_android")
        }

        @JvmStatic external fun nativeStop()
        @JvmStatic external fun nativeGetStats(): String?
        @JvmStatic external fun nativeGetLogs(sinceSeq: Long): String?

        const val ACTION_START = "com.ghoststream.vpn.START"
        const val ACTION_STOP  = "com.ghoststream.vpn.STOP"

        const val EXTRA_SERVER_ADDR = "server_addr"
        const val EXTRA_SERVER_NAME = "server_name"
        const val EXTRA_INSECURE    = "insecure"
        const val EXTRA_CERT_PATH   = "cert_path"
        const val EXTRA_KEY_PATH    = "key_path"
        const val EXTRA_TUN_ADDR    = "tun_addr"
        const val EXTRA_DNS_SERVERS = "dns_servers"

        private const val CHANNEL_ID      = "ghoststream_vpn"
        private const val NOTIFICATION_ID  = 1001
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

        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID, buildNotification("Подключение..."),
                FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Подключение..."))
        }

        startTunnel(serverAddr, serverName, insecure, certPath, keyPath, tunAddr, dnsServers)
        return START_STICKY
    }

    private fun startTunnel(
        serverAddr: String, serverName: String,
        insecure: Boolean, certPath: String, keyPath: String,
        tunAddr: String, dnsServers: List<String>,
    ) {
        val parts     = tunAddr.split("/")
        val tunIp     = parts.getOrElse(0) { "10.7.0.2" }
        val tunPrefix = parts.getOrNull(1)?.toIntOrNull() ?: 24

        val builder = Builder()
            .setSession("GhostStream")
            .addAddress(tunIp, tunPrefix)
            .addRoute("0.0.0.0", 0)
            .setMtu(1350)

        for (dns in dnsServers) {
            try { builder.addDnsServer(dns) } catch (_: Exception) {}
        }

        vpnInterface = builder.establish() ?: run {
            VpnStateManager.update(VpnState.Error("Не удалось создать TUN"))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        val fd = vpnInterface!!.fd
        val result = nativeStart(fd, serverAddr, serverName, insecure, certPath, keyPath)
        if (result != 0) {
            vpnInterface?.close()
            vpnInterface = null
            VpnStateManager.update(VpnState.Error("Ошибка запуска туннеля"))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }

        VpnStateManager.update(VpnState.Connected(serverName = serverName))
        val nm = getSystemService(NotificationManager::class.java)
        nm?.notify(NOTIFICATION_ID, buildNotification("Подключено: $serverAddr"))

        startWatchdog()
    }

    /**
     * Monitors native tunnel state. Cleans up VPN if:
     * - QUIC connect never succeeds (60s timeout)
     * - Tunnel drops after being connected
     */
    private fun startWatchdog() {
        watchdogThread?.interrupt()
        watchdogThread = Thread {
            var wasConnected = false
            var timeoutSecs = 60
            while (!Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    break
                }
                try {
                    val stats = nativeGetStats() ?: continue
                    val connected = stats.contains("\"connected\":true")
                    if (connected) {
                        wasConnected = true
                        timeoutSecs = Int.MAX_VALUE
                    }
                    if (!connected && wasConnected) {
                        mainHandler.post { stopTunnel() }
                        break
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
        watchdogThread?.interrupt()
        watchdogThread = null
        nativeStop()
        vpnInterface?.close()
        vpnInterface = null
        VpnStateManager.update(VpnState.Disconnected)
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
