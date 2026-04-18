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
import com.ghoststream.vpn.service.VpnStateManager
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

data class LogEntry(
    val seq: Long,
    val timestamp: String,
    val level: String,
    val message: String,
)

class LogsViewModel(application: Application) : AndroidViewModel(application) {

    companion object {
        private val LEVEL_ORDER = listOf("TRACE", "DEBUG", "INFO", "WARN", "ERROR")
    }

    private val allLogs = mutableListOf<LogEntry>()

    private val _logs = MutableStateFlow<List<LogEntry>>(emptyList())
    val logs: StateFlow<List<LogEntry>> = _logs

    private val _filter = MutableStateFlow("ALL")
    val filter: StateFlow<String> = _filter

    private val _autoScroll = MutableStateFlow(true)
    val autoScroll: StateFlow<Boolean> = _autoScroll

    private var nextSeq = 0L
    private val tsFormat = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    init {
        // Ensure Rust sends all log levels — filtering is UI-only.
        try { GhostStreamVpnService.nativeSetLogLevel("trace") } catch (_: Exception) {}

        // Collect push-based log frames from Rust via VpnStateManager.
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
                allLogs.add(
                    LogEntry(
                        seq = nextSeq++,
                        timestamp = tsFormat.format(Date(frame.tsUnixMs)),
                        level = levelNorm,
                        message = frame.msg,
                    ),
                )
                while (allLogs.size > 50000) allLogs.removeAt(0)
                applyFilter()
            }
        }
    }

    private fun applyFilter() {
        _logs.value = if (_filter.value == "ALL") {
            allLogs.toList()
        } else {
            val minIdx = LEVEL_ORDER.indexOf(_filter.value).let { if (it < 0) 0 else it }
            allLogs.filter {
                val idx = LEVEL_ORDER.indexOf(it.level)
                idx < 0 || idx >= minIdx
            }
        }
    }

    fun setFilter(level: String) {
        _filter.value = level
        applyFilter()
    }

    fun clearLogs() {
        allLogs.clear()
        _logs.value = emptyList()
    }

    fun copyEntry(context: Context, entry: LogEntry) {
        val text = "${entry.timestamp} ${entry.level} ${entry.message}"
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("log", text))
        Toast.makeText(context, "Скопировано", Toast.LENGTH_SHORT).show()
    }

    fun copyAll(context: Context) {
        val text = allLogs.joinToString("\n") { "${it.timestamp} ${it.level} ${it.message}" }
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newPlainText("logs", text))
        Toast.makeText(context, "Все логи скопированы (${allLogs.size})", Toast.LENGTH_SHORT).show()
    }

    fun shareLogs(context: Context) {
        val text = allLogs.joinToString("\n") { "${it.timestamp} ${it.level} ${it.message}" }
        if (text.isBlank()) {
            Toast.makeText(context, "Логи пусты", Toast.LENGTH_SHORT).show()
            return
        }
        val logsDir = File(context.cacheDir, "logs")
        logsDir.mkdirs()
        val file = File(logsDir, "ghoststream-logs.txt")
        file.writeText(text)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "Отправить логи"))
    }
}
