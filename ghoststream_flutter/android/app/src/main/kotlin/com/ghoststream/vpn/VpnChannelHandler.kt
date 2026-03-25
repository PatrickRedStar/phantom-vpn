package com.ghoststream.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.VpnState
import com.ghoststream.vpn.service.VpnStateManager
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collectLatest
import org.json.JSONArray
import org.json.JSONObject

class VpnChannelHandler(
    private val context: Context,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "ghoststream/vpn"
        const val STATE_CHANNEL = "ghoststream/vpn_state"
        const val STATS_CHANNEL = "ghoststream/vpn_stats"
        const val LOGS_CHANNEL = "ghoststream/vpn_logs"
        private const val TAG = "VpnChannelHandler"
        private const val VPN_PREPARE_REQUEST = 24601
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())

    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingVpnArgs: Map<String, Any?>? = null

    fun createStateStreamHandler(): EventChannel.StreamHandler {
        return object : EventChannel.StreamHandler {
            private var job: Job? = null
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                job = scope.launch {
                    VpnStateManager.state.collectLatest { state ->
                        val json = JSONObject().apply {
                            when (state) {
                                is VpnState.Disconnected -> put("state", "disconnected")
                                is VpnState.Connecting -> put("state", "connecting")
                                is VpnState.Connected -> {
                                    put("state", "connected")
                                    put("serverName", state.serverName)
                                }
                                is VpnState.Error -> {
                                    put("state", "error")
                                    put("message", state.message)
                                }
                                is VpnState.Disconnecting -> put("state", "disconnecting")
                            }
                        }
                        mainHandler.post { events?.success(json.toString()) }
                    }
                }
            }
            override fun onCancel(arguments: Any?) {
                job?.cancel()
            }
        }
    }

    fun createStatsStreamHandler(): EventChannel.StreamHandler {
        return object : EventChannel.StreamHandler {
            private var job: Job? = null
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                job = scope.launch {
                    while (isActive) {
                        try {
                            val raw = GhostStreamVpnService.nativeGetStats()
                            if (raw != null) {
                                mainHandler.post { events?.success(raw) }
                            }
                        } catch (_: Exception) {}
                        delay(1000)
                    }
                }
            }
            override fun onCancel(arguments: Any?) {
                job?.cancel()
            }
        }
    }

    fun createLogsStreamHandler(): EventChannel.StreamHandler {
        return object : EventChannel.StreamHandler {
            private var job: Job? = null
            private var lastSeq: Long = -1
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                lastSeq = -1
                job = scope.launch {
                    while (isActive) {
                        try {
                            val raw = GhostStreamVpnService.nativeGetLogs(lastSeq)
                            if (raw != null) {
                                val arr = JSONArray(raw)
                                if (arr.length() > 0) {
                                    val last = arr.getJSONObject(arr.length() - 1)
                                    lastSeq = last.optLong("seq", lastSeq)
                                    mainHandler.post { events?.success(raw) }
                                }
                            }
                        } catch (_: Exception) {}
                        delay(500)
                    }
                }
            }
            override fun onCancel(arguments: Any?) {
                job?.cancel()
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startVpn" -> {
                @Suppress("UNCHECKED_CAST")
                val args = call.arguments as? Map<String, Any?> ?: run {
                    result.error("INVALID_ARGS", "Expected map arguments", null)
                    return
                }

                val prepareIntent = VpnService.prepare(context)
                if (prepareIntent != null) {
                    pendingVpnResult = result
                    pendingVpnArgs = args
                    activity.startActivityForResult(prepareIntent, VPN_PREPARE_REQUEST)
                } else {
                    launchVpnService(args)
                    result.success(0)
                }
            }
            "stopVpn" -> {
                val intent = Intent(context, GhostStreamVpnService::class.java)
                    .setAction(GhostStreamVpnService.ACTION_STOP)
                context.startService(intent)
                result.success(null)
            }
            "setLogLevel" -> {
                val level = call.argument<String>("level") ?: "info"
                try {
                    GhostStreamVpnService.nativeSetLogLevel(level)
                } catch (_: Exception) {}
                result.success(null)
            }
            "computeVpnRoutes" -> {
                val path = call.argument<String>("path") ?: ""
                scope.launch {
                    val routes = try {
                        GhostStreamVpnService.nativeComputeVpnRoutes(path)
                    } catch (_: Exception) { null }
                    mainHandler.post { result.success(routes) }
                }
            }
            "prepareVpn" -> {
                val intent = VpnService.prepare(context)
                result.success(intent == null)
            }
            "getInstalledApps" -> {
                scope.launch {
                    val pm = context.packageManager
                    val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
                    val apps = pm.queryIntentActivities(intent, 0).mapNotNull { resolveInfo ->
                        val appInfo = resolveInfo.activityInfo?.applicationInfo ?: return@mapNotNull null
                        JSONObject().apply {
                            put("packageName", appInfo.packageName)
                            put("label", pm.getApplicationLabel(appInfo).toString())
                            put("isSystem", (appInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0)
                        }
                    }
                    val arr = JSONArray(apps)
                    mainHandler.post { result.success(arr.toString()) }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != VPN_PREPARE_REQUEST) return false
        val r = pendingVpnResult
        val args = pendingVpnArgs
        pendingVpnResult = null
        pendingVpnArgs = null

        if (resultCode == Activity.RESULT_OK && args != null) {
            launchVpnService(args)
            r?.success(0)
        } else {
            r?.error("VPN_DENIED", "User denied VPN permission", null)
        }
        return true
    }

    private fun launchVpnService(args: Map<String, Any?>) {
        val intent = Intent(context, GhostStreamVpnService::class.java).apply {
            action = GhostStreamVpnService.ACTION_START
            putExtra(GhostStreamVpnService.EXTRA_SERVER_ADDR, args["serverAddr"] as? String ?: "")
            putExtra(GhostStreamVpnService.EXTRA_SERVER_NAME, args["serverName"] as? String ?: "")
            putExtra(GhostStreamVpnService.EXTRA_INSECURE, args["insecure"] as? Boolean ?: false)
            putExtra(GhostStreamVpnService.EXTRA_CERT_PATH, args["certPath"] as? String ?: "")
            putExtra(GhostStreamVpnService.EXTRA_KEY_PATH, args["keyPath"] as? String ?: "")
            putExtra(GhostStreamVpnService.EXTRA_CA_CERT_PATH, args["caCertPath"] as? String ?: "")
            putExtra(GhostStreamVpnService.EXTRA_TUN_ADDR, args["tunAddr"] as? String ?: "10.7.0.2/24")
            putExtra(GhostStreamVpnService.EXTRA_DNS_SERVERS, args["dnsServers"] as? String ?: "8.8.8.8,1.1.1.1")
            putExtra(GhostStreamVpnService.EXTRA_SPLIT_ROUTING, args["splitRouting"] as? Boolean ?: false)
            putExtra(GhostStreamVpnService.EXTRA_DIRECT_CIDRS, args["directCidrsPath"] as? String ?: "")
            putExtra(GhostStreamVpnService.EXTRA_PER_APP_MODE, args["perAppMode"] as? String ?: "none")
            putExtra(GhostStreamVpnService.EXTRA_PER_APP_LIST, args["perAppList"] as? String ?: "")
        }

        VpnStateManager.update(VpnState.Connecting)
        context.startForegroundService(intent)
    }

    fun dispose() {
        scope.cancel()
    }
}
