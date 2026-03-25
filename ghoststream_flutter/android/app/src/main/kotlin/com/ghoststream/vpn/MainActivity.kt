package com.ghoststream.vpn

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var vpnHandler: VpnChannelHandler? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val handler = VpnChannelHandler(applicationContext, this)
        vpnHandler = handler

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, VpnChannelHandler.METHOD_CHANNEL)
            .setMethodCallHandler(handler)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VpnChannelHandler.STATE_CHANNEL)
            .setStreamHandler(handler.createStateStreamHandler())

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VpnChannelHandler.STATS_CHANNEL)
            .setStreamHandler(handler.createStatsStreamHandler())

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, VpnChannelHandler.LOGS_CHANNEL)
            .setStreamHandler(handler.createLogsStreamHandler())
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (vpnHandler?.handleActivityResult(requestCode, resultCode) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        vpnHandler?.dispose()
        vpnHandler = null
        super.onDestroy()
    }
}
