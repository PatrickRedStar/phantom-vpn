package com.ghoststream.vpn.service

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Service-scoped persister for `VpnStateManager.logFrames` → rotating on-disk
 * file. v0.27.0 (W4-1): hoisted from `LogsViewModel`. Previously the persister
 * lived on `viewModelScope`, so log lines were lost whenever the Logs screen
 * was off-stack — the user's "debug report says Логи пусты" bug.
 *
 * Process-singleton (`object`). State (writer, queue) survives multiple
 * `start()` calls; only the first wins. Disk file is the source of truth
 * across process restarts.
 *
 * Reads (for replay + debug-report tail) go through the static `tailLines` /
 * `allLogFiles` helpers — they don't touch the writer and can be called
 * before `start()`.
 */
object LogPersister {

    const val LOG_FILE = "ghoststream.log"
    const val LOG_DIR = "logs"
    const val ROTATE_AT_BYTES = 2L * 1024 * 1024
    const val ROTATE_KEEP = 5

    /** Same shape as the LogsViewModel writer used (yyyy-MM-dd HH:mm:ss.SSS). */
    private val fileTsFormat = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)

    /**
     * Persist queue. Capacity 4096 + `DROP_OLDEST` mirrors the old
     * LogsViewModel buffer — at TRACE Rust can emit 100+ frames/sec; dropping
     * the *oldest* undrained entry preserves the newest (errors after a
     * reconnect, etc.) which are most useful for diagnosis.
     */
    private val persistQueue = Channel<Pair<LogFrameData, Long>>(
        capacity = 4096,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    @Volatile private var currentWriter: BufferedWriter? = null
    @Volatile private var activeFile: File? = null
    @Volatile private var started = false

    /**
     * Launch the producer (`VpnStateManager.logFrames` → queue) and the
     * single IO consumer (queue → file). Idempotent — second and later calls
     * are no-ops. `scope` is typically `GhostStreamVpnService.serviceScope`;
     * lives as long as the foreground service (i.e. as long as the tunnel
     * has ever been started this session).
     */
    fun start(context: Context, scope: CoroutineScope) {
        synchronized(this) {
            if (started) return
            started = true
        }
        val dir = File(context.applicationContext.filesDir, LOG_DIR).apply { mkdirs() }
        activeFile = File(dir, LOG_FILE)

        // Single consumer that drains the queue and writes sequentially. No
        // race on `currentWriter` because only this coroutine touches it.
        scope.launch(Dispatchers.IO) {
            for ((frame, ts) in persistQueue) {
                appendPersisted(frame, ts)
            }
        }

        // Producer: every log frame from Rust → queue. Hot SharedFlow,
        // collector never finishes (scope cancellation ends it).
        scope.launch {
            VpnStateManager.logFrames.collect { frame ->
                persistQueue.trySend(frame to frame.tsUnixMs)
            }
        }
    }

    /**
     * Best-effort flush of the buffered writer so a subsequent file read
     * (e.g. share-logs, debug-report) sees the latest entries.
     */
    fun flushPending() {
        runCatching { currentWriter?.flush() }
    }

    /**
     * Return up to [n] most recent lines from the active log file. If the
     * active file has fewer than `n / 4` lines (i.e. it just rotated and is
     * nearly empty), also reads the immediately preceding `.0` file and
     * concatenates so the result is never artificially truncated.
     *
     * Safe to call before `start()` — reads directly from disk.
     */
    fun tailLines(context: Context, n: Int): List<String> {
        val dir = File(context.applicationContext.filesDir, LOG_DIR)
        if (!dir.exists()) return emptyList()
        val active = File(dir, LOG_FILE)
        val activeLines = if (active.exists()) {
            runCatching { active.readLines() }.getOrDefault(emptyList())
        } else {
            emptyList()
        }
        if (activeLines.size >= n / 4 || activeLines.size >= n) {
            return activeLines.takeLast(n)
        }
        val prev = File(dir, "$LOG_FILE.0")
        if (!prev.exists()) return activeLines.takeLast(n)
        val prevLines = runCatching { prev.readLines() }.getOrDefault(emptyList())
        return (prevLines + activeLines).takeLast(n)
    }

    /**
     * Return the on-disk log file set in chronological order:
     * `.4` (oldest existing) … `.0` (just-rotated) … active. Used by
     * `LogsViewModel.shareLogs` to concatenate the full session log.
     *
     * Safe to call before `start()`.
     */
    fun allLogFiles(context: Context): List<File> {
        val dir = File(context.applicationContext.filesDir, LOG_DIR)
        if (!dir.exists()) return emptyList()
        val parts = mutableListOf<File>()
        val base = File(dir, LOG_FILE).absolutePath
        for (n in (ROTATE_KEEP - 1) downTo 0) {
            val f = File("$base.$n")
            if (f.exists()) parts.add(f)
        }
        val active = File(dir, LOG_FILE)
        if (active.exists()) parts.add(active)
        return parts
    }

    // ── Internal ──────────────────────────────────────────────────────────

    private fun appendPersisted(frame: LogFrameData, tsUnixMs: Long) {
        val target = activeFile ?: return
        runCatching {
            if (target.length() >= ROTATE_AT_BYTES) {
                currentWriter?.flush()
                currentWriter?.close()
                currentWriter = null
                rotateFiles(target)
            }
            if (currentWriter == null) {
                currentWriter = BufferedWriter(FileWriter(target, true))
            }
            currentWriter?.appendLine(formatForFile(frame, tsUnixMs))
            currentWriter?.flush()
        }
    }

    private fun rotateFiles(active: File) {
        val base = active.absolutePath
        val oldest = File("$base.${ROTATE_KEEP - 1}")
        if (oldest.exists()) oldest.delete()
        for (n in (ROTATE_KEEP - 2) downTo 0) {
            val src = File("$base.$n")
            val dst = File("$base.${n + 1}")
            if (src.exists()) src.renameTo(dst)
        }
        active.renameTo(File("$base.0"))
    }

    /**
     * Same format as the previous LogsViewModel writer:
     * `yyyy-MM-dd HH:mm:ss.SSS LEVEL [category] msg k1=v1 k2=v2`
     *
     * Level is normalized from Rust's 3-char codes (ERR/WRN/INF/DBG/TRC) to
     * the full names so the replay parser and downstream tools see the same
     * tokens whether or not the line was written before or after this
     * refactor.
     */
    private fun formatForFile(frame: LogFrameData, tsUnixMs: Long): String {
        val ts = fileTsFormat.format(Date(tsUnixMs))
        val level = when (frame.level) {
            "ERR" -> "ERROR"
            "WRN" -> "WARN"
            "INF" -> "INFO"
            "DBG" -> "DEBUG"
            "TRC" -> "TRACE"
            else -> frame.level
        }
        val cat = frame.category?.let { "[$it] " } ?: ""
        val fields = if (frame.fields.isEmpty()) {
            ""
        } else {
            " " + frame.fields.entries.joinToString(" ") { (k, v) -> "$k=$v" }
        }
        return "$ts $level $cat${frame.msg}$fields"
    }
}
