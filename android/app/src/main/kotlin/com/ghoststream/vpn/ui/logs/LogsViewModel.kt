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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File

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

    private val _filter = MutableStateFlow("INFO")
    val filter: StateFlow<String> = _filter

    private val _autoScroll = MutableStateFlow(true)
    val autoScroll: StateFlow<Boolean> = _autoScroll

    private var lastSeq = -1L

    init {
        viewModelScope.launch {
            while (true) {
                fetchNewLogs()
                delay(500)
            }
        }
    }

    private suspend fun fetchNewLogs() {
        val changed = withContext(Dispatchers.Default) {
            try {
                val json = GhostStreamVpnService.nativeGetLogs(lastSeq) ?: return@withContext false
                if (json == "[]") return@withContext false
                val arr = JSONArray(json)
                var hasChanges = false
                for (i in 0 until arr.length()) {
                    val obj = arr.getJSONObject(i)
                    val seq = obj.optLong("seq", -1)
                    if (seq <= lastSeq) continue
                    allLogs.add(
                        LogEntry(
                            seq = seq,
                            timestamp = obj.optString("ts", ""),
                            level = obj.optString("level", "INFO"),
                            message = obj.optString("msg", ""),
                        ),
                    )
                    if (seq > lastSeq) lastSeq = seq
                    hasChanges = true
                }
                while (allLogs.size > 50000) allLogs.removeAt(0)
                hasChanges
            } catch (_: Exception) {
                false
            }
        }
        if (changed) applyFilter()
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
        val rustLevel = when (level) {
            "TRACE" -> "trace"
            "DEBUG" -> "debug"
            "INFO"  -> "info"
            "WARN"  -> "warn"
            "ERROR" -> "error"
            else    -> "trace"  // ALL → show everything
        }
        try {
            GhostStreamVpnService.nativeSetLogLevel(rustLevel)
        } catch (_: Exception) {}
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
        // Clipboard Binder ограничен ~1 MB — берём последние 500 строк, остальное — через share
        val limit = 500
        val source = if (allLogs.size > limit) allLogs.takeLast(limit) else allLogs
        val text = source.joinToString("\n") { "${it.timestamp} ${it.level} ${it.message}" }
        try {
            val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText("logs", text))
            val msg = if (allLogs.size > limit)
                "Скопированы последние $limit строк из ${allLogs.size}"
            else
                "Скопировано ${allLogs.size} строк"
            Toast.makeText(context, msg, Toast.LENGTH_SHORT).show()
        } catch (_: Exception) {
            Toast.makeText(context, "Слишком много данных — используй «Поделиться»", Toast.LENGTH_LONG).show()
        }
    }

    fun shareLogs(context: Context) {
        viewModelScope.launch {
            val uri = withContext(Dispatchers.IO) {
                val text = allLogs.joinToString("\n") { "${it.timestamp} ${it.level} ${it.message}" }
                if (text.isBlank()) return@withContext null
                val logsDir = File(context.cacheDir, "logs")
                logsDir.mkdirs()
                val file = File(logsDir, "ghoststream-logs.txt")
                file.writeText(text)
                FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
            }
            if (uri == null) {
                Toast.makeText(context, "Логи пусты", Toast.LENGTH_SHORT).show()
                return@launch
            }
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "Отправить логи"))
        }
    }
}
