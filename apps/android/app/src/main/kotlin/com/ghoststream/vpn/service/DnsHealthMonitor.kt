package com.ghoststream.vpn.service

import android.content.Context
import android.net.ConnectivityManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.net.InetAddress

/**
 * Does name resolution actually work *through the tunnel*?
 *
 * Why this exists: a tunnel can be perfectly healthy at the byte level and still
 * be useless. On 2026-07-31 the tunnel pushed 6.8 MB/s while not a single name
 * resolved — the dashboard showed a green "Передача." and 8/8 streams the whole
 * time, so the failure was invisible for weeks. Stream count and byte counters
 * cannot see this class of breakage; only an actual resolve can.
 *
 * Deliberately measures the outcome rather than reasoning about causes. Two
 * separate mechanisms were proposed for that incident and BOTH were disproved by
 * measurement, so the monitor reports "names don't resolve" as a fact and only
 * names a culprit when the system tells us one (strict Private DNS below).
 */
sealed class DnsHealth {
    /** No probe has run yet, or the tunnel is down. */
    data object Unknown : DnsHealth()

    /** First probe of this session is in flight. */
    data object Probing : DnsHealth()

    /** [resolver] — which server actually answered. See [DnsHealthMonitor.resolverLabel]. */
    data class Ok(val latencyMs: Int, val resolver: String?) : DnsHealth()

    /**
     * Resolution is failing. [strictPrivateDnsHost] is non-null only when the
     * system reports strict-mode Private DNS — then the UI may name it. Never
     * hardcode a hostname: this is whatever the user configured, read back from
     * the platform.
     */
    data class Dead(
        val failures: Int,
        val strictPrivateDnsHost: String?,
        val resolver: String?,
    ) : DnsHealth()
}

object DnsHealthMonitor {

    private const val TAG = "GhostStreamDns"

    /** A single resolve gets this long before it counts as a failure. */
    private const val PROBE_TIMEOUT_MS = 5_000L

    /** Re-probe cadence while healthy. Cheap (usually a cache hit), so keep it calm. */
    private const val INTERVAL_OK_MS = 30_000L

    /** Re-probe cadence while failing — we want the UI to recover quickly. */
    private const val INTERVAL_FAILING_MS = 5_000L

    private val _state = MutableStateFlow<DnsHealth>(DnsHealth.Unknown)
    val state: StateFlow<DnsHealth> = _state.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null

    /**
     * Start probing [probeHost] — pass the active profile's server name. Using
     * our own infrastructure keeps the probe off third parties, and that name
     * has to resolve for the tunnel to be usable at all, so a failure here is
     * exactly the failure the user cares about.
     */
    fun start(context: Context, probeHost: String) {
        stop()
        if (probeHost.isBlank()) return
        val appContext = context.applicationContext
        job = scope.launch {
            _state.value = DnsHealth.Probing
            var consecutiveFailures = 0
            var firstFailureAt = 0L
            while (isActive) {
                val latency = probeOnce(probeHost)
                val strictHost = strictPrivateDnsHost(appContext)
                val resolver = resolverLabel(appContext, strictHost)
                if (latency != null) {
                    consecutiveFailures = 0
                    firstFailureAt = 0L
                    _state.value = DnsHealth.Ok(latency, resolver)
                } else {
                    consecutiveFailures++
                    if (firstFailureAt == 0L) firstFailureAt = elapsedMs()
                    val failingForMs = elapsedMs() - firstFailureAt
                    if (shouldReportDead(consecutiveFailures, failingForMs)) {
                        _state.value = DnsHealth.Dead(
                            failures = consecutiveFailures,
                            strictPrivateDnsHost = strictHost,
                            resolver = resolver,
                        )
                    }
                }
                delay(if (consecutiveFailures > 0) INTERVAL_FAILING_MS else INTERVAL_OK_MS)
            }
        }
    }

    fun stop() {
        job?.cancel()
        job = null
        _state.value = DnsHealth.Unknown
    }

    /**
     * Decides whether a run of failed probes is bad enough to tell the user DNS
     * is broken.
     *
     * The trade-off is real in both directions. Report too eagerly and every
     * lift ride or handover paints a red banner over a tunnel that is fine, and
     * the user learns to ignore it. Report too late and they sit in front of an
     * app that claims everything is green while nothing opens — which is the
     * exact failure this monitor exists to end.
     */
    internal fun shouldReportDead(consecutiveFailures: Int, failingForMs: Long): Boolean {
        // Three failures AND at least 20 s of them. Deliberately biased towards
        // waiting: the failure this monitor exists for (a DNS setup that cannot
        // work through the tunnel) lasts until someone changes something, so a
        // slightly late warning costs nothing. Short dropouts on mobile happen
        // constantly, and a banner that cries wolf is one the user stops reading.
        //
        // Both conditions on purpose. Failures alone would fire early if probes
        // fail fast (connection refused rather than timeout); elapsed time alone
        // would fire on a single unlucky 20 s stall.
        return consecutiveFailures >= 3 && failingForMs >= 20_000
    }

    /** Latency in ms, or null if the resolve failed or timed out. */
    private suspend fun probeOnce(host: String): Int? = withContext(Dispatchers.IO) {
        val started = elapsedMs()
        val ok = withTimeoutOrNull(PROBE_TIMEOUT_MS) {
            runCatching { InetAddress.getAllByName(host).isNotEmpty() }.getOrDefault(false)
        } ?: false
        if (ok) (elapsedMs() - started).toInt() else null
    }

    /**
     * The strict-mode Private DNS hostname the *system* is configured with, or
     * null when strict mode is off.
     *
     * Read through the public `LinkProperties` API rather than `Settings.Global`
     * so we get the platform's own view, and never a hardcoded hostname. When
     * strict mode is on, Android is required to send every query to this server
     * over DoT and refuses to fall back — so if that server is unreachable from
     * inside the tunnel, DNS stops entirely.
     */
    private fun strictPrivateDnsHost(context: Context): String? {
        // `Settings.Global` first. LinkProperties.privateDnsServerName looked like
        // the tidier source, but on a live device with strict mode ON it came back
        // null for every network the app can see — so the banner fell back to its
        // generic text and never named the culprit. The global setting is what the
        // user actually typed, and it is what the resolver obeys.
        runCatching {
            val mode = android.provider.Settings.Global.getString(
                context.contentResolver, "private_dns_mode",
            )
            if (mode == "hostname") {
                val host = android.provider.Settings.Global.getString(
                    context.contentResolver, "private_dns_specifier",
                )
                if (!host.isNullOrBlank()) return host
            } else if (mode != null) {
                // Mode is known and is not strict — no override in play.
                return null
            }
        }.onFailure { Log.w(TAG, "private DNS setting read failed: ${it.message}") }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return null
        return runCatching {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
            val networks = listOfNotNull(cm.activeNetwork) + cm.allNetworks.toList()
            networks.asSequence()
                .mapNotNull { cm.getLinkProperties(it) }
                .firstNotNullOfOrNull { lp -> lp.privateDnsServerName?.takeIf { it.isNotBlank() } }
        }.onFailure { Log.w(TAG, "private DNS lookup failed: ${it.message}") }.getOrNull()
    }

    /**
     * Which server is *actually* resolving, for display.
     *
     * Needed because "through the tunnel" alone misleads: the same address can be
     * configured both in the app and in the phone, and strict Private DNS silently
     * overrides whatever the tunnel asked for. Naming the server makes that
     * override visible instead of leaving the user to guess.
     *
     * Strict Private DNS wins when set — that is the resolver in force regardless
     * of the tunnel's own DNS servers. Otherwise report the first DNS address the
     * VPN network actually carries.
     */
    private fun resolverLabel(context: Context, strictHost: String?): String? {
        if (strictHost != null) return "$strictHost · DoT"
        return runCatching {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return null
            cm.allNetworks.asSequence()
                .mapNotNull { cm.getLinkProperties(it) }
                .firstOrNull { it.interfaceName?.startsWith("tun") == true }
                ?.dnsServers
                ?.firstOrNull()
                ?.hostAddress
        }.getOrNull()
    }

    private fun elapsedMs(): Long = android.os.SystemClock.elapsedRealtime()
}
