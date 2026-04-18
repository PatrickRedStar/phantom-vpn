package com.ghoststream.vpn.ui.logs

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.R
import com.ghoststream.vpn.ui.components.HeaderMeta
import com.ghoststream.vpn.ui.components.GhostChip
import com.ghoststream.vpn.ui.components.ScreenHeader
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText

@Composable
fun LogsScreen(viewModel: LogsViewModel) {
    val logs by viewModel.logs.collectAsStateWithLifecycle()
    val filter by viewModel.filter.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val context = LocalContext.current

    // When new logs come in, snap the reversed list to newest item (index 0).
    LaunchedEffect(logs.size) {
        if (logs.isNotEmpty()) {
            runCatching { listState.animateScrollToItem(0) }
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(C.bg),
    ) {
        ScreenHeader(
            brand = stringResource(R.string.brand_tail),
            meta = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    HeaderMeta(
                        text = "${stringResource(R.string.hdr_meta_live)} · " +
                            stringResource(R.string.hdr_meta_lines, formatCount(logs.size)),
                        pulse = true,
                    )
                }
            },
        )

        // Chip row — horizontal scroll so chips never truncate.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            listOf(
                "ALL"   to stringResource(R.string.chip_all),
                "TRACE" to stringResource(R.string.chip_trace),
                "DEBUG" to stringResource(R.string.chip_debug),
                "INFO"  to stringResource(R.string.chip_info),
                "WARN"  to stringResource(R.string.chip_warn),
                "ERROR" to stringResource(R.string.chip_error),
            ).forEach { (code, label) ->
                GhostChip(
                    text = label,
                    active = filter == code,
                    onClick = { viewModel.setFilter(code) },
                )
            }
            GhostChip(
                text = stringResource(R.string.chip_share),
                active = false,
                onClick = { viewModel.shareLogs(context) },
                accent = C.signal,
            )
        }

        // Log list + fade-out gradient overlay.
        Box(Modifier.fillMaxSize()) {
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize(),
                reverseLayout = true,
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = 16.dp, end = 16.dp, top = 8.dp, bottom = 80.dp,
                ),
            ) {
                items(logs.asReversed(), key = { it.seq }) { entry ->
                    LogEntryRow(entry)
                }
            }

            // Bottom fade-out to warm-black.
            val fadeBg = C.bg
            Box(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .height(50.dp)
                    .drawBehind {
                        drawRect(
                            brush = Brush.verticalGradient(
                                0f to Color.Transparent,
                                1f to fadeBg,
                            ),
                        )
                    },
            )
        }
    }
}

@Composable
private fun LogEntryRow(entry: LogEntry) {
    val lvlColor = when (entry.level.uppercase()) {
        "ERROR" -> C.danger
        "WARN"  -> C.warn
        "INFO"  -> C.signal
        "DEBUG" -> BlueDebug
        "TRACE" -> C.textFaint
        "OK"    -> C.signal
        else    -> C.textDim
    }
    val msgColor = when (entry.level.uppercase()) {
        "ERROR" -> C.danger.copy(alpha = 0.85f)
        "WARN"  -> C.warn.copy(alpha = 0.8f)
        "DEBUG" -> BlueDebug.copy(alpha = 0.7f)
        "TRACE" -> C.textFaint
        else    -> C.bone
    }
    val rowBg = when (entry.level.uppercase()) {
        "ERROR" -> C.danger.copy(alpha = 0.08f)
        "WARN"  -> C.warn.copy(alpha = 0.05f)
        else    -> Color.Transparent
    }
    val lvlShort = when (entry.level.uppercase()) {
        "ERROR" -> "ERR"
        "WARN"  -> "WRN"
        "INFO"  -> "INF"
        "DEBUG" -> "DBG"
        "TRACE" -> "TRC"
        else    -> entry.level.take(3).uppercase()
    }

    Row(
        Modifier
            .fillMaxWidth()
            .background(rowBg)
            .drawBehind {
                // Left accent bar
                drawRect(
                    color = lvlColor,
                    topLeft = Offset.Zero,
                    size = androidx.compose.ui.geometry.Size(2.dp.toPx(), size.height),
                )
            }
            .padding(start = 6.dp, top = 2.dp, bottom = 2.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = shortTs(entry.timestamp),
            style = GsText.logTs,
            color = C.textFaint,
            modifier = Modifier.width(54.dp),
        )
        Text(
            text = lvlShort,
            style = GsText.labelMono,
            color = lvlColor,
            modifier = Modifier.width(32.dp),
        )
        Spacer(Modifier.width(4.dp))
        Text(
            text = entry.message,
            style = GsText.logMsg,
            color = msgColor,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/** Strip leading date if timestamp has form "YYYY-MM-DD HH:MM:SS". */
private fun shortTs(ts: String): String {
    val sp = ts.indexOf(' ')
    return if (sp in 1 until ts.length - 1) ts.substring(sp + 1) else ts
}

private fun formatCount(n: Int): String = when {
    n < 1000 -> n.toString()
    n < 1_000_000 -> "${n / 1000}.${(n % 1000) / 100}k"
    else -> "${n / 1_000_000}M"
}
