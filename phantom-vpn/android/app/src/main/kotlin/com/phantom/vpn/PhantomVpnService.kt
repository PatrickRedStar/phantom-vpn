package com.phantom.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
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
            insecure: Boolean
        ): Int

        @JvmStatic external fun nativeStop()

        const val ACTION_START = "com.phantom.vpn.START"
        const val ACTION_STOP  = "com.phantom.vpn.STOP"

        const val EXTRA_SERVER_ADDR = "server_addr"
        const val EXTRA_SERVER_NAME = "server_name"
        const val EXTRA_INSECURE    = "insecure"

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
        val serverName = intent?.getStringExtra(EXTRA_SERVER_NAME)
            ?: serverAddr.substringBefore(":")
        val insecure   = intent?.getBooleanExtra(EXTRA_INSECURE, true) ?: true

        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("Connecting…"))
        startTunnel(serverAddr, serverName, insecure)

        return START_STICKY
    }

    private fun startTunnel(serverAddr: String, serverName: String, insecure: Boolean) {
        // Build TUN interface (Android gives us a fd)
        val builder = Builder()
            .setSession("PhantomVPN")
            .addAddress("10.7.0.2", 24)
            .addRoute("0.0.0.0", 0)        // full tunnel
            .setMtu(1350)
            .addDnsServer("8.8.8.8")
            .addDnsServer("1.1.1.1")

        vpnInterface = builder.establish() ?: run {
            stopSelf()
            return
        }

        // detachFd() transfers ownership — Rust will close it when done
        val fd = vpnInterface!!.detachFd()
        val result = nativeStart(fd, serverAddr, serverName, insecure)
        if (result != 0) {
            stopSelf()
            return
        }

        // Update notification to Connected
        val nm = getSystemService(NotificationManager::class.java)
        nm?.notify(NOTIFICATION_ID, buildNotification("Connected to $serverAddr"))
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

    // ─── Notification ────────────────────────────────────────────────────────

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL,
                "PhantomVPN",
                NotificationManager.IMPORTANCE_LOW
            ).apply { description = "VPN tunnel status" }
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(text: String): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, PhantomVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("PhantomVPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null, "Disconnect", stopIntent
                ).build()
            )
            .build()
    }
}
