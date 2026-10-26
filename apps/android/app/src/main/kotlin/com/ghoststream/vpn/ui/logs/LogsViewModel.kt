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
import com.ghoststream.vpn.R
import com.ghoststream.vpn.service.GhostStreamVpnService
import com.ghoststream.vpn.service.LogPersister
import com.ghoststream.vpn.service.VpnStateManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
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
    /** Сколько подряд идущих одинаковых строк свёрнуто в эту. 1 = нет свёртки. */
    val repeats: Int = 1,
)

class LogsViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private val LEVEL_ORDER = listOf("TRACE", "DEBUG", "INFO", "WARN", "ERROR")

        /** "[дата ]время УРОВЕНЬ [категория] сообщение" — дата опциональна. */
        private val LOG_LINE_RE = Regex(
            """^(?:\d{4}-\d{2}-\d{2}\s+)?(\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s+(\S+)(?:\s+\[([^]]*)])?\s*(.*)$""",
        )
        /** Max lines kept in RAM for the live tail. */
        private const val MAX_LIVE_LINES = 10_000
        /** A burst of frames re-filters the list at most this often. */
        private const val FILTER_THROTTLE_MS = 250L
        const val ALL_CATEGORIES = "all"
        /** The core's everyday filter (logsink default; set_level adds the noisy-crate caps). */
        private const val DEFAULT_LOG_SPEC =
            "info,client_core_runtime=debug,phantom_core=info,client_common=debug"

        /** Parse one persisted line; seq is assigned by the caller on the main thread. */
        private fun parsePersisted(line: String): LogEntry {
            // Format: "[yyyy-MM-dd ]HH:mm:ss[.SSS] LEVEL [cat] msg k=v k=v"
            //
            // Дата опциональна. Прежний парсер её ТРЕБОВАЛ (искал пробел с
            // индекса 11) и на строках без даты сдвигал все поля на одну
            // колонку: уровень попадал в timestamp, категория — в уровень.
            // Это ломало не только вид, но и фильтр по уровням (level
            // становился "[TU"). Баг-репорт 2026-08-01.
            val m = LOG_LINE_RE.matchEntire(line.trim()) ?: return LogEntry(0, "", "INFO", line)
            val (displayTs, level, catRaw, msg) = m.destructured
            return LogEntry(0, displayTs, level, msg, category = catRaw.ifEmpty { null })
        }
    }

    // Main thread only (viewModelScope runs on Main): the history replay
    // parses on IO but merges here, so the list and seq never race.
    private val allLogs = ArrayDeque<LogEntry>()
    private var filterJob: Job? = null

    private val _logs = MutableStateFlow<List<LogEntry>>(emptyList())
    val logs: StateFlow<List<LogEntry>> = _logs

    // ADR 0015: по умолчанию INFO — DEBUG-рукопожатия засоряли экран
    // (мин-порог: INFO показывает INFO/WARN/ERROR).
    private val _filter = MutableStateFlow("INFO")
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
    private var visible = false
    private val tsFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    init {
        // Replay previously persisted logs so the user has context across
        // app restarts. v0.27.0 (W4-1): persist file is owned by
        // `LogPersister` (service-scoped) — tailLines() is safe to call
        // even before the service has started writing this session.
        viewModelScope.launch {
            val history = withContext(Dispatchers.IO) {
                runCatching {
                    LogPersister.tailLines(application, MAX_LIVE_LINES).map(::parsePersisted)
                }.getOrDefault(emptyList())
            }
            // Live frames that arrived meanwhile are newer — history goes in front.
            for (e in history.asReversed()) allLogs.addFirst(e.copy(seq = nextSeq++))
            while (allLogs.size > MAX_LIVE_LINES) allLogs.removeFirst()
            history.forEach { e -> e.category?.let { seenCategories.add(it) } }
            _availableCategories.value = seenCategories.toList()
            applyFilter()
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
                allLogs.addLast(entry)
                while (allLogs.size > MAX_LIVE_LINES) allLogs.removeFirst()

                // Track categories for filter chips.
                frame.category?.let {
                    if (seenCategories.add(it)) {
                        _availableCategories.value = seenCategories.toList()
                    }
                }

                scheduleFilter()
            }
        }
    }

    private fun scheduleFilter() {
        if (filterJob?.isActive == true) return
        filterJob = viewModelScope.launch {
            delay(FILTER_THROTTLE_MS)
            applyFilter()
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
        }.let(::collapseRepeats)
    }

    /**
     * Сворачивает подряд идущие одинаковые строки в одну со счётчиком.
     *
     * Системные колбэки сети (`onCapabilitiesChanged`) валятся десятками
     * подряд и превращали журнал в стену одинакового текста. Свёртка
     * сохраняет ПОСЛЕДНЮЮ строку группы (у неё свежий таймстемп) и её
     * `repeats` — так видно и факт повторов, и их число, а экран остаётся
     * читаемым.
     */
    private fun collapseRepeats(list: List<LogEntry>): List<LogEntry> {
        if (list.size < 2) return list
        val out = ArrayList<LogEntry>(list.size)
        var run = list[0]
        var n = 1
        for (i in 1 until list.size) {
            val e = list[i]
            val same = e.level == run.level &&
                e.category == run.category &&
                e.message == run.message
            if (same) {
                n++
                run = e // держим самый свежий таймстемп группы
            } else {
                out.add(if (n > 1) run.copy(repeats = n) else run)
                run = e
                n = 1
            }
        }
        out.add(if (n > 1) run.copy(repeats = n) else run)
        return out
    }

    fun setFilter(level: String) {
        _filter.value = level
        applyFilter()
        applyLogLevel()
    }

    /** The journal is on screen: Logs tab selected, app in foreground. */
    fun setVisible(v: Boolean) {
        visible = v
        applyLogLevel()
    }

    // The core logs as verbosely as the chosen filter needs, and only while
    // the journal is on screen: trace on every packet costs CPU, battery and
    // LogPersister disk writes.
    private fun applyLogLevel() {
        val level = when {
            !visible -> DEFAULT_LOG_SPEC
            _filter.value == "TRACE" || _filter.value == "ALL" -> "trace"
            _filter.value == "DEBUG" -> "debug"
            else -> DEFAULT_LOG_SPEC
        }
        runCatching { GhostStreamVpnService.nativeSetLogLevel(level) }
    }

    fun setCategoryFilter(category: String) {
        _categoryFilter.value = category
        applyFilter()
    }

    fun setSearchQuery(query: String) {
        _searchQuery.value = query
        applyFilter()
    }

    /** Clears the screen and the journal on disk (persisted file, share/debug exports). */
    fun clearLogs() {
        allLogs.clear()
        _logs.value = emptyList()
        seenCategories.clear()
        _availableCategories.value = emptyList()
        val ctx = getApplication<Application>()
        viewModelScope.launch(Dispatchers.IO) {
            runCatching {
                LogPersister.flushPending()
                for (f in LogPersister.allLogFiles(ctx)) {
                    // LogPersister keeps the active file open in append mode:
                    // truncate it in place — after unlinking, new lines would
                    // go to a file nobody can read.
                    if (f.name == LogPersister.LOG_FILE) java.io.FileOutputStream(f).close() else f.delete()
                }
                File(ctx.cacheDir, "logs").deleteRecursively()
                File(ctx.cacheDir, "debug").deleteRecursively()
            }
        }
    }

    fun copyEntry(context: Context, entry: LogEntry) {
        val text = "${entry.timestamp} ${entry.level} ${entry.message}"
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("log", text))
        Toast.makeText(context, R.string.logs_copied, Toast.LENGTH_SHORT).show()
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
        Toast.makeText(context, context.getString(R.string.logs_copied_all, allLogs.size), Toast.LENGTH_SHORT).show()
    }

    /**
     * Share the entire on-disk log set (active file + rotated .0….N) as a
     * single .txt attachment. v0.24.0: now includes structured fields and
     * categories, and reads from the persistent files instead of just RAM.
     */
    fun shareLogs(context: Context) {
        val snapshot = allLogs.toList()
        viewModelScope.launch(Dispatchers.IO) {
            runCatching {
                // Flush any buffered live writes so the share captures the
                // very latest entries. v0.27.0: writer owned by LogPersister.
                LogPersister.flushPending()
                val parts = LogPersister.allLogFiles(context)

                val out = File(File(context.cacheDir, "logs").apply { mkdirs() }, "ghoststream-session.log")
                out.bufferedWriter().use { w ->
                    if (parts.isEmpty()) {
                        // Fallback to RAM-only snapshot.
                        snapshot.forEach { entry ->
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
                        Toast.makeText(context, R.string.logs_empty, Toast.LENGTH_SHORT).show()
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
                    context.startActivity(Intent.createChooser(intent, context.getString(R.string.logs_share_title)))
                }
            }.onFailure { e ->
                withContext(Dispatchers.Main) {
                    Toast.makeText(context, context.getString(R.string.logs_failed, e.message ?: ""), Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    override fun onCleared() {
        super.onCleared()
        visible = false
        applyLogLevel()
    }
}
