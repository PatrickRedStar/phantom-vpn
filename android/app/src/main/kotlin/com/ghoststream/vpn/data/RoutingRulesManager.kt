package com.ghoststream.vpn.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Downloads, caches, and merges geoip CIDR lists from v2fly/geoip.
 * Text format: one CIDR per line (e.g. "1.0.0.0/24").
 */
class RoutingRulesManager(private val context: Context) {

    private val rulesDir: File
        get() = File(context.filesDir, "routing_rules").also { it.mkdirs() }

    data class RuleInfo(
        val code: String,
        val label: String,
        val sizeKb: Long,
        val lastUpdated: Long,
        val cidrCount: Int = 0,
    )

    companion object {
        // v2fly/geoip releases provide plain text CIDR files per country
        private const val BASE_URL =
            "https://raw.githubusercontent.com/v2fly/geoip/release/text"

        val AVAILABLE_COUNTRIES = listOf(
            "ru" to "Россия",
            "by" to "Беларусь",
            "kz" to "Казахстан",
            "ua" to "Украина",
            "cn" to "Китай",
            "ir" to "Иран",
            "private" to "Приватные сети",
        )

        // Android VpnService has Binder payload limits during Builder.establish().
        // We coarsen dense country lists to keep route table manageable.
        private const val ANDROID_MAX_IPV4_PREFIX = 18
    }

    fun sourceUrl(code: String): String = "$BASE_URL/$code.txt"

    fun getDownloadedRules(): List<RuleInfo> {
        return AVAILABLE_COUNTRIES.mapNotNull { (code, label) ->
            val file = File(rulesDir, "$code.txt")
            if (file.exists()) {
                val count = file.bufferedReader().useLines { lines ->
                    lines.count { it.isNotBlank() }
                }
                RuleInfo(code, label, file.length() / 1024, file.lastModified(), count)
            } else {
                null
            }
        }
    }

    fun isDownloaded(code: String): Boolean = File(rulesDir, "$code.txt").exists()

    suspend fun downloadRuleList(code: String): Result<Long> = withContext(Dispatchers.IO) {
        try {
            val conn = (URL(sourceUrl(code)).openConnection() as HttpURLConnection).apply {
                connectTimeout = 10_000
                readTimeout = 20_000
                requestMethod = "GET"
            }
            if (conn.responseCode != 200) {
                val body = conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
                conn.disconnect()
                return@withContext Result.failure(IllegalStateException("HTTP ${conn.responseCode}: $body"))
            }
            val text = conn.inputStream.bufferedReader().use(BufferedReader::readText)
            conn.disconnect()
            val file = File(rulesDir, "$code.txt")
            file.writeText(text)
            Result.success(file.length())
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun deleteRuleList(code: String) {
        File(rulesDir, "$code.txt").delete()
    }

    /**
     * Merge selected country lists into a single file for nativeComputeVpnRoutes().
     * Returns path to merged file, or null if no lists selected/downloaded.
     */
    fun mergeSelectedLists(countryCodes: List<String>): String? {
        var count = 0
        val outFile = File(rulesDir, "direct_merged.txt")
        if (outFile.exists()) outFile.delete()
        val mergedCidrs = LinkedHashSet<String>()
        outFile.bufferedWriter().use { writer ->
            for (code in countryCodes) {
                val file = File(rulesDir, "$code.txt")
                if (file.exists()) {
                    file.forEachLine { line ->
                        val normalized = normalizeForAndroidSplitRouting(line)
                        if (normalized != null) {
                            mergedCidrs.add(normalized)
                        }
                    }
                    count++
                }
            }
            mergedCidrs.forEach { writer.appendLine(it) }
        }
        if (count == 0) return null

        return outFile.absolutePath
    }

    fun missingSelectedLists(countryCodes: List<String>): List<String> =
        countryCodes.filterNot { File(rulesDir, "$it.txt").exists() }

    fun previewRuleList(code: String, maxLines: Int = 30): List<String> {
        val file = File(rulesDir, "$code.txt")
        if (!file.exists()) return emptyList()
        val result = ArrayList<String>(maxLines)
        file.bufferedReader().useLines { lines ->
            lines.filter { it.isNotBlank() }.take(maxLines).forEach { result.add(it) }
        }
        return result
    }

    private fun normalizeForAndroidSplitRouting(line: String): String? {
        val cidr = line.trim()
        if (cidr.isBlank() || cidr.startsWith("#")) return null
        // IPv6 rules dramatically increase route count and currently are not practical here.
        if (cidr.contains(":")) return null

        val parts = cidr.split("/", limit = 2)
        if (parts.size != 2) return null
        val addr = parts[0]
        val prefix = parts[1].toIntOrNull() ?: return null
        if (prefix !in 0..32) return null

        val ipv4 = ipv4ToInt(addr) ?: return null
        val effectivePrefix = minOf(prefix, ANDROID_MAX_IPV4_PREFIX)
        val mask = if (effectivePrefix == 0) 0 else (-1 shl (32 - effectivePrefix))
        val network = ipv4 and mask
        return "${intToIpv4(network)}/$effectivePrefix"
    }

    private fun ipv4ToInt(ip: String): Int? {
        val octets = ip.split(".")
        if (octets.size != 4) return null
        var result = 0
        for (o in octets) {
            val n = o.toIntOrNull() ?: return null
            if (n !in 0..255) return null
            result = (result shl 8) or n
        }
        return result
    }

    private fun intToIpv4(value: Int): String {
        val a = (value ushr 24) and 0xFF
        val b = (value ushr 16) and 0xFF
        val c = (value ushr 8) and 0xFF
        val d = value and 0xFF
        return "$a.$b.$c.$d"
    }
}
