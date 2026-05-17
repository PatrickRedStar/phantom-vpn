package com.ghoststream.vpn.ui.logs

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.R
import com.ghoststream.vpn.ui.components.HeaderMeta
import com.ghoststream.vpn.ui.components.GhostChip
import com.ghoststream.vpn.ui.components.ScreenHeader
import com.ghoststream.vpn.ui.components.isTabletExpanded
import com.ghoststream.vpn.ui.components.isTabletPortrait
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText

@Composable
fun LogsScreen(viewModel: LogsViewModel) {
    val logs by viewModel.logs.collectAsStateWithLifecycle()
    val filter by viewModel.filter.collectAsStateWithLifecycle()
    val categoryFilter by viewModel.categoryFilter.collectAsStateWithLifecycle()
    val searchQuery by viewModel.searchQuery.collectAsStateWithLifecycle()
    val availableCategories by viewModel.availableCategories.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()
    val context = LocalContext.current

    // When new logs come in, snap the reversed list to newest item (index 0).
    LaunchedEffect(logs.size) {
        if (logs.isNotEmpty()) {
            runCatching { listState.animateScrollToItem(0) }
        }
    }

    // v0.26.3: 2-pane layout on tablet/foldable expanded (Material Expanded class).
    // Filter pane on the left (240 dp), log list on the right with full width for
    // unobstructed log lines. Compact + Medium portrait keep the existing 1-column
    // scroll behaviour: search box → horizontal level chip-row → horizontal
    // category chip-row → LazyColumn. Per-level toggles are NOT implemented —
    // LogsViewModel only exposes a min-threshold filter, so the same chip-row
    // semantics are reused in the wide-layout filter pane.
    val twoPane = isTabletExpanded()

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

        if (twoPane) {
            Row(Modifier.fillMaxSize()) {
                FilterPane(
                    modifier = Modifier
                        .width(240.dp)
                        .fillMaxHeight()
                        .background(C.bgElev),
                    searchQuery = searchQuery,
                    onSearchChange = { viewModel.setSearchQuery(it) },
                    levelFilter = filter,
                    onLevelChange = { viewModel.setFilter(it) },
                    availableCategories = availableCategories,
                    categoryFilter = categoryFilter,
                    onCategoryChange = { viewModel.setCategoryFilter(it) },
                    onClearLogs = { viewModel.clearLogs() },
                    onShareLogs = { viewModel.shareLogs(context) },
                )
                Box(
                    Modifier
                        .width(1.dp)
                        .fillMaxHeight()
                        .background(C.hair),
                )
                LogList(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight(),
                    logs = logs,
                    listState = listState,
                )
            }
        } else {
            // ── Search box ────────────────────────────────────────────────
            // Free-text filter over message / category / field values.
            // Substring, case-insensitive. Empty = pass-through. v0.24.0.
            SearchBox(
                value = searchQuery,
                onChange = { viewModel.setSearchQuery(it) },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
            )

            // Level chips (horizontal scroll) — current Compact behaviour.
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 6.dp),
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
                    text = stringResource(R.string.chip_clear),
                    active = false,
                    onClick = { viewModel.clearLogs() },
                    accent = C.textDim,
                )
                GhostChip(
                    text = stringResource(R.string.chip_share),
                    active = false,
                    onClick = { viewModel.shareLogs(context) },
                    accent = C.signal,
                )
            }

            // Category chips — only visible once Rust has emitted at least one
            // categorised log this session. Keeps the UI clean for users who
            // never look beyond the level filter. v0.24.0.
            if (availableCategories.isNotEmpty()) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .horizontalScroll(rememberScrollState())
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    GhostChip(
                        text = stringResource(R.string.chip_cat_all),
                        active = categoryFilter == LogsViewModel.ALL_CATEGORIES,
                        onClick = { viewModel.setCategoryFilter(LogsViewModel.ALL_CATEGORIES) },
                    )
                    availableCategories.forEach { cat ->
                        GhostChip(
                            text = cat,
                            active = categoryFilter == cat,
                            onClick = { viewModel.setCategoryFilter(cat) },
                        )
                    }
                }
            }

            LogList(
                modifier = Modifier.fillMaxSize(),
                logs = logs,
                listState = listState,
            )
        }
    }
}

/**
 * Vertical filter pane shown on tablet/foldable expanded layouts (v0.26.3).
 *
 * Stack from top to bottom:
 *  - "FILTER" section label
 *  - Search box (full-width within pane)
 *  - "УРОВЕНЬ" label + vertical column of level chips (ALL / TRACE / DEBUG /
 *    INFO / WARN / ERROR). Reuses the same `GhostChip` rendered horizontally
 *    on Compact — same active=lime semantics so the user has a single mental
 *    model for "which level am I filtering on".
 *  - "КАТЕГОРИЯ" label + vertical column of category chips, ALL plus every
 *    category Rust has emitted this session.
 *  - "ДЕЙСТВИЯ" label + vertical CLEAR / SHARE chips.
 *
 * Per-level toggles (Info/Warn/Err/Dbg/Trc independent switches) are *not*
 * implemented because LogsViewModel doesn't expose `setLevelEnabled` /
 * `enabledLevels` — only a single min-threshold via `setFilter`. Adding
 * the API would balloon v0.26.3 scope. The min-threshold chips below give
 * the user equivalent filtering for the common cases (hide INFO and below
 * via WARN, only see ERROR, etc.).
 */
@Composable
private fun FilterPane(
    modifier: Modifier = Modifier,
    searchQuery: String,
    onSearchChange: (String) -> Unit,
    levelFilter: String,
    onLevelChange: (String) -> Unit,
    availableCategories: List<String>,
    categoryFilter: String,
    onCategoryChange: (String) -> Unit,
    onClearLogs: () -> Unit,
    onShareLogs: () -> Unit,
) {
    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        SectionLabel(stringResource(R.string.chip_all).let { "FILTER" })
        Spacer(Modifier.height(6.dp))
        SearchBox(
            value = searchQuery,
            onChange = onSearchChange,
            modifier = Modifier.fillMaxWidth(),
        )

        Spacer(Modifier.height(14.dp))
        SectionLabel("УРОВЕНЬ")
        Spacer(Modifier.height(6.dp))
        val levelOptions = listOf(
            "ALL"   to stringResource(R.string.chip_all),
            "TRACE" to stringResource(R.string.chip_trace),
            "DEBUG" to stringResource(R.string.chip_debug),
            "INFO"  to stringResource(R.string.chip_info),
            "WARN"  to stringResource(R.string.chip_warn),
            "ERROR" to stringResource(R.string.chip_error),
        )
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            levelOptions.forEach { (code, label) ->
                GhostChip(
                    text = label,
                    active = levelFilter == code,
                    onClick = { onLevelChange(code) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }

        Spacer(Modifier.height(14.dp))
        SectionLabel("КАТЕГОРИЯ")
        Spacer(Modifier.height(6.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            GhostChip(
                text = stringResource(R.string.chip_cat_all),
                active = categoryFilter == LogsViewModel.ALL_CATEGORIES,
                onClick = { onCategoryChange(LogsViewModel.ALL_CATEGORIES) },
                modifier = Modifier.fillMaxWidth(),
            )
            if (availableCategories.isEmpty()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    text = "—",
                    style = GsText.labelMono,
                    color = C.textFaint,
                    modifier = Modifier.padding(start = 4.dp),
                )
            } else {
                availableCategories.forEach { cat ->
                    GhostChip(
                        text = cat,
                        active = categoryFilter == cat,
                        onClick = { onCategoryChange(cat) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }

        Spacer(Modifier.height(14.dp))
        SectionLabel("ДЕЙСТВИЯ")
        Spacer(Modifier.height(6.dp))
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            GhostChip(
                text = stringResource(R.string.chip_clear),
                active = false,
                onClick = onClearLogs,
                accent = C.textDim,
                modifier = Modifier.fillMaxWidth(),
            )
            GhostChip(
                text = stringResource(R.string.chip_share),
                active = false,
                onClick = onShareLogs,
                accent = C.signal,
                modifier = Modifier.fillMaxWidth(),
            )
        }

        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text,
        style = GsText.labelMono,
        color = C.textFaint,
        modifier = Modifier.padding(start = 2.dp),
    )
}

/**
 * Shared search input — `BasicTextField` with the hairline-bordered box
 * styling used everywhere in Ghoststream. Extracted so the same control
 * renders in both the Compact 1-column header and the wide-layout filter
 * pane. v0.26.3.
 */
@Composable
private fun SearchBox(
    value: String,
    onChange: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier
            .background(C.bgElev)
            .border(0.5.dp, C.hair)
            .padding(horizontal = 10.dp, vertical = 8.dp),
    ) {
        if (value.isEmpty()) {
            Text(
                text = stringResource(R.string.logs_search_hint),
                style = GsText.body,
                color = C.textFaint,
            )
        }
        BasicTextField(
            value = value,
            onValueChange = onChange,
            singleLine = true,
            textStyle = TextStyle(
                fontSize = 13.sp,
                color = C.bone,
            ),
            cursorBrush = SolidColor(C.signal),
            keyboardOptions = KeyboardOptions(
                capitalization = KeyboardCapitalization.None,
                autoCorrect = false,
                imeAction = ImeAction.Search,
            ),
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

/**
 * Log list with bottom fade-out gradient. Shared between Compact (full-width
 * below filter strip) and wide (right pane). Same `LazyColumn` semantics —
 * `reverseLayout = true` keeps the newest entry at the bottom of the screen
 * while still allowing auto-scroll to "newest" via `animateScrollToItem(0)`.
 */
@Composable
private fun LogList(
    modifier: Modifier = Modifier,
    logs: List<LogEntry>,
    listState: LazyListState,
) {
    Box(modifier) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            reverseLayout = true,
            contentPadding = PaddingValues(
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

    // Structured fields toggle: rows with `fields` start collapsed; tap row
    // to expand. Cheap state — one bool per visible row. v0.24.0.
    var expanded by remember(entry.seq) { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxWidth()
            .background(rowBg)
            .drawBehind {
                drawRect(
                    color = lvlColor,
                    topLeft = Offset.Zero,
                    size = androidx.compose.ui.geometry.Size(2.dp.toPx(), size.height),
                )
            }
            .let { if (entry.fields.isNotEmpty()) it.clickable { expanded = !expanded } else it }
            .padding(start = 6.dp, top = 2.dp, bottom = 2.dp),
    ) {
        Row(verticalAlignment = Alignment.Top) {
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
            Column(Modifier.fillMaxWidth()) {
                // First line: optional category badge + the message body.
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (entry.category != null) {
                        Text(
                            text = entry.category,
                            style = GsText.labelMono,
                            color = C.textDim,
                            modifier = Modifier
                                .background(C.bgElev2)
                                .border(0.5.dp, C.hair)
                                .padding(horizontal = 4.dp, vertical = 1.dp),
                        )
                        Spacer(Modifier.width(6.dp))
                    }
                    Text(
                        text = entry.message + if (entry.fields.isNotEmpty() && !expanded) " …" else "",
                        style = GsText.logMsg,
                        color = msgColor,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                // Expanded structured fields rendering: one row per k=v.
                if (expanded && entry.fields.isNotEmpty()) {
                    Column(Modifier.padding(top = 2.dp, start = 4.dp)) {
                        entry.fields.forEach { (k, v) ->
                            Row {
                                Text(
                                    text = "$k=",
                                    style = GsText.logMsg,
                                    color = C.textDim,
                                )
                                Text(
                                    text = v,
                                    style = GsText.logMsg,
                                    color = msgColor,
                                )
                            }
                        }
                    }
                }
            }
        }
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
