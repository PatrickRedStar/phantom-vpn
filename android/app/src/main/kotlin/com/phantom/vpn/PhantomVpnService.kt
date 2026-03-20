package com.phantom.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor

class PhantomVpnService : VpnService() {

    private var vpnInterface: ParcelFileDescriptor? = null

    companion object {
        init {
            System.loadLibrary("phantom_android")
        }

        @JvmStatic external fun nativeStart(
            tunFd: Int,
            serverAddr: String,
            serverName: String,
            insecure: Boolean,
            certPath: String,
            keyPath: String,
        ): Int

        @JvmStatic external fun nativeStop()

        const val ACTION_START = "com.phantom.vpn.START"
        const val ACTION_STOP  = "com.phantom.vpn.STOP"

        const val EXTRA_SERVER_ADDR = "server_addr"
        const val EXTRA_SERVER_NAME = "server_name"
        const val EXTRA_INSECURE    = "insecure"
        const val EXTRA_CERT_PATH   = "cert_path"
        const val EXTRA_KEY_PATH    = "key_path"
        const val EXTRA_TUN_ADDR    = "tun_addr"

        private const val NOTIFICATION_CHANNEL = "phantom_vpn_channel"
        private const val NOTIFICATION_ID      = 1001
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopTunnel()
            stopSelf()
            return START_NOT_STICKY
        }

        val serverAddr = intent?.getStringExtra(EXTRA_SERVER_ADDR) ?: return START_NOT_STICKY
        val serverName = intent.getStringExtra(EXTRA_SERVER_NAME)
            ?: serverAddr.substringBefore(":")
        val insecure   = intent.getBooleanExtra(EXTRA_INSECURE, false)
        val certPath   = intent.getStringExtra(EXTRA_CERT_PATH) ?: ""
        val keyPath    = intent.getStringExtra(EXTRA_KEY_PATH)  ?: ""
        val tunAddr    = intent.getStringExtra(EXTRA_TUN_ADDR)  ?: "10.7.0.2/24"

        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, buildNotification("Подключение…"),
                FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification("Подключение…"))
        }
        startTunnel(serverAddr, serverName, insecure, certPath, keyPath, tunAddr)

        return START_STICKY
    }

    private fun startTunnel(
        serverAddr: String, serverName: String,
        insecure: Boolean, certPath: String, keyPath: String,
        tunAddr: String,
    ) {
        // Разбираем "10.7.0.6/24" → ip="10.7.0.6", prefix=24
        val parts     = tunAddr.split("/")
        val tunIp     = parts.getOrElse(0) { "10.7.0.2" }
        val tunPrefix = parts.getOrNull(1)?.toIntOrNull() ?: 24

        val builder = Builder()
            .setSession("PhantomVPN")
            .addAddress(tunIp, tunPrefix)
            .addRoute("0.0.0.0", 0)
            .setMtu(1350)
            .addDnsServer("8.8.8.8")
            .addDnsServer("1.1.1.1")

        vpnInterface = builder.establish() ?: run { stopSelf(); return }

        val fd = vpnInterface!!.detachFd()
        val result = nativeStart(fd, serverAddr, serverName, insecure, certPath, keyPath)
        if (result != 0) {
            stopSelf()
            return
        }

        val nm = getSystemService(NotificationManager::class.java)
        nm?.notify(NOTIFICATION_ID, buildNotification("Подключено: $serverAddr"))
    }

    private fun stopTunnel() {
        nativeStop()
        vpnInterface?.close()
        vpnInterface = null
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL, "PhantomVPN", NotificationManager.IMPORTANCE_LOW
            ).apply { description = "Статус VPN туннеля" }
            getSystemService(NotificationManager::class.java)?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, PhantomVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        else @Suppress("DEPRECATION") Notification.Builder(this)

        return builder
            .setContentTitle("PhantomVPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Отключить", stopIntent).build())
            .build()
    }
}
