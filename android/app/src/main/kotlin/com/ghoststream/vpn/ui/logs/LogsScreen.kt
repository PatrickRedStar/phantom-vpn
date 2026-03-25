package com.ghoststream.vpn.ui.logs

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.LocalGhostColors
import com.ghoststream.vpn.ui.theme.RedError
import com.ghoststream.vpn.ui.theme.YellowWarning

@Composable
fun LogsScreen(viewModel: LogsViewModel) {
    val gc = LocalGhostColors.current
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

    Box(Modifier.fillMaxSize().testTag("overlay_logs")) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize().padding(horizontal = 8.dp),
            contentPadding = PaddingValues(top = 48.dp, bottom = 8.dp),
        ) {
            items(logs) { entry ->
                LogEntryRow(entry, onLongClick = { viewModel.copyEntry(context, entry) })
            }
        }

        // Floating glass controls bar with custom filter chips
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(gc.cardBg)
                .border(0.5.dp, gc.cardBorder)
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(
                modifier = Modifier
                    .weight(1f)
                    .horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                listOf("ALL", "TRACE", "DEBUG", "INFO", "WARN", "ERROR").forEach { level ->
                    LogFilterChip(
                        text = level,
                        isActive = filter == level,
                        onClick = { viewModel.setFilter(level) },
                    )
                }
            }
        }
    }
}

@Composable
private fun LogFilterChip(text: String, isActive: Boolean, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    val bg = if (isActive) AccentPurple.copy(alpha = 0.12f) else Color.Transparent
    val border = if (isActive) AccentPurple.copy(alpha = 0.5f) else gc.cardBorder
    val textColor = if (isActive) AccentPurple else gc.textTertiary

    Text(
        text = text,
        fontSize = 10.sp,
        fontWeight = FontWeight.SemiBold,
        letterSpacing = 0.4.sp,
        color = textColor,
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(16.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 5.dp),
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LogEntryRow(entry: LogEntry, onLongClick: () -> Unit) {
    val gc = LocalGhostColors.current
    val color = when (entry.level) {
        "ERROR" -> RedError
        "WARN" -> YellowWarning
        "DEBUG" -> BlueDebug
        else -> gc.textSecondary
    }
    Row(
        Modifier
            .fillMaxWidth()
            .combinedClickable(onLongClick = onLongClick, onClick = {})
            .padding(vertical = 2.dp)
            .then(
                Modifier
                    .border(
                        width = 0.dp,
                        color = Color.White.copy(alpha = 0.03f),
                    )
                    .padding(bottom = 1.dp),
            ),
    ) {
        Text(
            entry.timestamp,
            style = androidx.compose.ui.text.TextStyle(
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
            ),
            color = gc.textTertiary,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            entry.level.padEnd(5),
            style = androidx.compose.ui.text.TextStyle(
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
            ),
            color = color,
        )
        Spacer(Modifier.width(6.dp))
        Text(
            entry.message,
            style = androidx.compose.ui.text.TextStyle(
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
            ),
            color = gc.textSecondary,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
