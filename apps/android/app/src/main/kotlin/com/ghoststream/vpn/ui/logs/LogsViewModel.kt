package com.ghoststream.vpn.ui.logs

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.LogPersister
import com.ghoststream.vpn.service.VpnStateManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * One UI row of the Logs screen. Carries v0.24.0 / ADR 0008 structured
 * fields so the screen can render key/value pairs and filter by category.
 */
data class LogEntry(
    val seq: Long,
    val timestamp: String,
    val level: String,
    val message: String,
    /** Logical category — one of: tunnel, handshake, network, stream,
     *  packet, telemetry, tun, ipc, settings, runtime, ffi. Null = legacy. */
    val category: String? = null,
    /** Stringified key/value attributes from the structured emitter. */
    val fields: Map<String, String> = emptyMap(),
)

class LogsViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private val LEVEL_ORDER = listOf("TRACE", "DEBUG", "INFO", "WARN", "ERROR")
        /** Max lines kept in RAM for the live tail. */
        private const val MAX_LIVE_LINES = 50_000
        const val ALL_CATEGORIES = "all"
    }

    private val allLogs = mutableListOf<LogEntry>()

    private val _logs = MutableStateFlow<List<LogEntry>>(emptyList())
    val logs: StateFlow<List<LogEntry>> = _logs

    private val _filter = MutableStateFlow("ALL")
    val filter: StateFlow<String> = _filter

    /** Active category filter ("all" or a specific category string). v0.24.0. */
    private val _categoryFilter = MutableStateFlow(ALL_CATEGORIES)
    val categoryFilter: StateFlow<String> = _categoryFilter

    /** Free-text search query — case-insensitive substring match over
     *  message / category / field values. v0.24.0. */
    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery

    /** Set of categories observed so far this session — used to populate
     *  filter chips. v0.24.0. */
    private val _availableCategories = MutableStateFlow<List<String>>(emptyList())
    val availableCategories: StateFlow<List<String>> = _availableCategories
    private val seenCategories = linkedSetOf<String>()

    private val _autoScroll = MutableStateFlow(true)
    val autoScroll: StateFlow<Boolean> = _autoScroll

    private var nextSeq = 0L
    private val tsFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    init {
        // Ensure Rust sends all log levels — filtering is UI-only.
        try { GhostStreamVpnService.nativeSetLogLevel("trace") } catch (_: Exception) {}

        // Replay previously persisted logs so the user has context across
        // app restarts. v0.27.0 (W4-1): persist file is owned by
        // `LogPersister` (service-scoped) — tailLines() is safe to call
        // even before the service has started writing this session.
        viewModelScope.launch(Dispatchers.IO) {
            replayPersistedLogs(application.applicationContext)
        }

        // Collect push-based log frames from Rust via VpnStateManager for UI
        // display. Persistence is handled by `LogPersister` (service-scoped),
        // independently of this ViewModel's lifecycle — moved off
        // viewModelScope in v0.27.0 (W4-1) so logs survive Logs-screen close.
        viewModelScope.launch {
            VpnStateManager.logFrames.collect { frame ->
                val levelNorm = when (frame.level) {
                    "ERR" -> "ERROR"
                    "WRN" -> "WARN"
                    "INF" -> "INFO"
                    "DBG" -> "DEBUG"
                    "TRC" -> "TRACE"
                    else -> frame.level
                }
                val entry = LogEntry(
                    seq = nextSeq++,
                    timestamp = tsFormat.format(Date(frame.tsUnixMs)),
                    level = levelNorm,
                    message = frame.msg,
                    category = frame.category,
                    fields = frame.fields,
                )
                allLogs.add(entry)
                while (allLogs.size > MAX_LIVE_LINES) allLogs.removeAt(0)

                // Track categories for filter chips.
                frame.category?.let {
                    if (seenCategories.add(it)) {
                        _availableCategories.value = seenCategories.toList()
                    }
                }

                applyFilter()
            }
        }
    }

    private fun applyFilter() {
        val level = _filter.value
        val cat = _categoryFilter.value
        val query = _searchQuery.value.trim().lowercase()

        val minIdx = if (level == "ALL") -1 else LEVEL_ORDER.indexOf(level).let { if (it < 0) 0 else it }

        _logs.value = allLogs.filter { entry ->
            val passLevel = if (minIdx < 0) true else {
                val idx = LEVEL_ORDER.indexOf(entry.level)
                idx < 0 || idx >= minIdx
            }
            val passCat = cat == ALL_CATEGORIES || entry.category == cat
            val passQuery = if (query.isEmpty()) true else {
                entry.message.lowercase().contains(query) ||
                    (entry.category?.lowercase()?.contains(query) ?: false) ||
                    entry.fields.any { (k, v) ->
                        k.lowercase().contains(query) || v.lowercase().contains(query)
                    }
            }
            passLevel && passCat && passQuery
        }
    }

    fun setFilter(level: String) {
        _filter.value = level
        applyFilter()
    }

    fun setCategoryFilter(category: String) {
        _categoryFilter.value = category
        applyFilter()
    }

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
        applyFilter()
    }

    fun clearLogs() {
        allLogs.clear()
        _logs.value = emptyList()
        seenCategories.clear()
        _availableCategories.value = emptyList()
    }

    /**
     * Read previously-persisted log lines from `LogPersister`'s on-disk file
     * and seed `allLogs` so the user has historical context across app
     * restarts and across Logs-screen open/close cycles. Best-effort; parse
     * failures fall through as plain-text rows. v0.24.0; v0.27.0: source
     * moved to LogPersister (service-scoped).
     */
    private fun replayPersistedLogs(context: Context) {
        runCatching {
            val take = LogPersister.tailLines(context, MAX_LIVE_LINES)
            if (take.isEmpty()) return@runCatching
            val parsed = mutableListOf<LogEntry>()
            for (line in take) {
                // Format: "yyyy-MM-dd HH:mm:ss.SSS LEVEL [cat] msg k=v k=v"
                // Parse softly — anything that doesn't match is shown as-is.
                val space1 = line.indexOf(' ', 11) // after date
                val space2 = if (space1 >= 0) line.indexOf(' ', space1 + 1) else -1
                val space3 = if (space2 >= 0) line.indexOf(' ', space2 + 1) else -1
                if (space3 < 0) {
                    parsed.add(LogEntry(nextSeq++, "", "INFO", line))
                    continue
                }
                val tsPart = line.substring(0, space2).trim()
                val level = line.substring(space2 + 1, space3).trim()
                val rest = line.substring(space3 + 1).trim()
                var cat: String? = null
                var msg = rest
                if (rest.startsWith("[")) {
                    val close = rest.indexOf(']')
                    if (close > 0) {
                        cat = rest.substring(1, close)
                        msg = rest.substring(close + 1).trim()
                    }
                }
                // Convert "yyyy-MM-dd HH:mm:ss.SSS" → "HH:mm:ss.SSS"
                val displayTs = if (tsPart.length >= 23) tsPart.substring(11) else tsPart
                parsed.add(
                    LogEntry(
                        seq = nextSeq++,
                        timestamp = displayTs,
                        level = level,
                        message = msg,
                        category = cat,
                    ),
                )
                if (cat != null && seenCategories.add(cat)) {
                    _availableCategories.value = seenCategories.toList()
                }
            }
            allLogs.addAll(0, parsed)
            while (allLogs.size > MAX_LIVE_LINES) allLogs.removeAt(0)
            applyFilter()
        }
    }

    fun copyEntry(context: Context, entry: LogEntry) {
        val text = "${entry.timestamp} ${entry.level} ${entry.message}"
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("log", text))
        Toast.makeText(context, "Скопировано", Toast.LENGTH_SHORT).show()
    }

    fun copyAll(context: Context) {
        val text = allLogs.joinToString("\n") { entry ->
            val cat = entry.category?.let { "[$it] " } ?: ""
            val fields = if (entry.fields.isEmpty()) "" else " " +
                entry.fields.entries.joinToString(" ") { (k, v) -> "$k=$v" }
            "${entry.timestamp} ${entry.level} $cat${entry.message}$fields"
        }
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("logs", text))
        Toast.makeText(context, "Все логи скопированы (${allLogs.size})", Toast.LENGTH_SHORT).show()
    }

    /**
     * Share the entire on-disk log set (active file + rotated .0….N) as a
     * single .txt attachment. v0.24.0: now includes structured fields and
     * categories, and reads from the persistent files instead of just RAM.
     */
    fun shareLogs(context: Context) {
        viewModelScope.launch(Dispatchers.IO) {
            runCatching {
                // Flush any buffered live writes so the share captures the
                // very latest entries. v0.27.0: writer owned by LogPersister.
                LogPersister.flushPending()
                val parts = LogPersister.allLogFiles(context)

                val out = File(context.cacheDir.apply { mkdirs() }, "ghoststream-session.log")
                out.bufferedWriter().use { w ->
                    if (parts.isEmpty()) {
                        // Fallback to RAM-only snapshot.
                        allLogs.forEach { entry ->
                            val cat = entry.category?.let { "[$it] " } ?: ""
                            val fields = if (entry.fields.isEmpty()) "" else " " +
                                entry.fields.entries.joinToString(" ") { (k, v) -> "$k=$v" }
                            w.appendLine("${entry.timestamp} ${entry.level} $cat${entry.message}$fields")
                        }
                    } else {
                        parts.forEach { p ->
                            p.bufferedReader().use { r ->
                                r.copyTo(w)
                            }
                        }
                    }
                }

                if (out.length() == 0L) {
                    withContext(Dispatchers.Main) {
                        Toast.makeText(context, "Логи пусты", Toast.LENGTH_SHORT).show()
                    }
                    return@runCatching
                }

                val uri = FileProvider.getUriForFile(
                    context,
                    "${context.packageName}.fileprovider",
                    out,
                )
                val intent = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_STREAM, uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                withContext(Dispatchers.Main) {
                    context.startActivity(Intent.createChooser(intent, "Отправить логи"))
                }
            }.onFailure { e ->
                withContext(Dispatchers.Main) {
                    Toast.makeText(context, "Не удалось: ${e.message}", Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        // v0.27.0: persistence lifecycle moved to LogPersister (service-scoped).
        // Nothing to tear down here — viewModelScope cancels its own coroutines.
    }
}
