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
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import java.io.File

data class LogEntry(
    val seq: Long,
    val timestamp: String,
    val level: String,
    val message: String,
)

class LogsViewModel(application: Application) : AndroidViewModel(application) {

    private val allLogs = mutableListOf<LogEntry>()

    private val _logs = MutableStateFlow<List<LogEntry>>(emptyList())
    val logs: StateFlow<List<LogEntry>> = _logs

    private val _filter = MutableStateFlow("ALL")
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

    private fun fetchNewLogs() {
        try {
            val json = GhostStreamVpnService.nativeGetLogs(lastSeq) ?: return
            if (json == "[]") return
            val arr = JSONArray(json)
            var changed = false
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
                changed = true
            }
            while (allLogs.size > 50000) allLogs.removeAt(0)
            if (changed) applyFilter()
        } catch (_: Exception) {}
    }

    private fun applyFilter() {
        _logs.value = if (_filter.value == "ALL") {
            allLogs.toList()
        } else {
            allLogs.filter { it.level == _filter.value }
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
