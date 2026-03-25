package com.ghoststream.vpn.data

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
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
    }

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
            val url = "$BASE_URL/$code.txt"
            val text = URL(url).readText()
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
    suspend fun mergeSelectedLists(countryCodes: List<String>): String? = withContext(Dispatchers.IO) {
        val merged = StringBuilder()
        var count = 0
        for (code in countryCodes) {
            val file = File(rulesDir, "$code.txt")
            if (file.exists()) {
                merged.append(file.readText())
                merged.append('\n')
                count++
            }
        }
        if (count == 0) return@withContext null

        val outFile = File(rulesDir, "direct_merged.txt")
        outFile.writeText(merged.toString())
        outFile.absolutePath
    }
}
