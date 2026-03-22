package com.ghoststream.vpn.ui.logs

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.RedError
import com.ghoststream.vpn.ui.theme.TextPrimary
import com.ghoststream.vpn.ui.theme.TextSecondary
import com.ghoststream.vpn.ui.theme.YellowWarning

@Composable
fun LogsScreen(viewModel: LogsViewModel) {
    val logs by viewModel.logs.collectAsStateWithLifecycle()
    val filter by viewModel.filter.collectAsStateWithLifecycle()
    val autoScroll by viewModel.autoScroll.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val context = LocalContext.current

    LaunchedEffect(logs.size, autoScroll) {
        if (autoScroll && logs.isNotEmpty()) {
            listState.animateScrollToItem(logs.size - 1)
        }
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            // Filter chips — scrollable so they don't overflow action buttons
            Row(
                modifier = Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                listOf("ALL", "TRACE", "DEBUG", "INFO", "WARN", "ERROR").forEach { level ->
                    FilterChip(
                        selected = filter == level,
                        onClick = { viewModel.setFilter(level) },
                        label = { Text(level, fontSize = 11.sp) },
                    )
                }
            }
            // Action buttons — always visible on the right
            IconButton(onClick = { viewModel.copyAll(context) }) {
                Icon(Icons.Filled.ContentCopy, "Копировать все")
            }
            IconButton(onClick = { viewModel.shareLogs(context) }) {
                Icon(Icons.Filled.Share, "Отправить")
            }
            TextButton(onClick = { viewModel.clearLogs() }) {
                Icon(Icons.Filled.Delete, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text("Очистить", fontSize = 12.sp)
            }
        }

        LazyColumn(
            state = listState,
            modifier = Modifier
                .fillMaxSize()
                .background(Color(0xFF0A0A0A))
                .padding(horizontal = 8.dp),
        ) {
            items(logs) { entry ->
                LogEntryRow(entry, onLongClick = { viewModel.copyEntry(context, entry) })
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LogEntryRow(entry: LogEntry, onLongClick: () -> Unit) {
    val color = when (entry.level) {
        "ERROR" -> RedError
        "WARN"  -> YellowWarning
        "DEBUG" -> BlueDebug
        else    -> TextSecondary
    }
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(onLongClick = onLongClick, onClick = {})
            .padding(vertical = 2.dp),
    ) {
        Text(
            entry.timestamp,
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace, fontSize = 11.sp,
            ),
            color = TextSecondary,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            entry.level.padEnd(5),
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace, fontSize = 11.sp, fontWeight = FontWeight.Bold,
            ),
            color = color,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            entry.message,
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace, fontSize = 11.sp,
            ),
            color = TextPrimary,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
