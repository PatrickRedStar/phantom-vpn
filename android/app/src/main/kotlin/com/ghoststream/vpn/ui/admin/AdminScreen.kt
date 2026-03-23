package com.ghoststream.vpn.ui.admin

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.AccentTeal
import com.ghoststream.vpn.ui.theme.DangerRose
import com.ghoststream.vpn.ui.theme.LocalGhostColors
import com.ghoststream.vpn.ui.theme.RedError
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

enum class ClientFilter { ALL, ONLINE, DISABLED }

@Composable
fun AdminScreen(
    adminUrl: String,
    adminToken: String,
    onBack: () -> Unit,
    viewModel: AdminViewModel = viewModel(),
) {
    val gc = LocalGhostColors.current
    val context = LocalContext.current

    LaunchedEffect(adminUrl, adminToken) { viewModel.init(adminUrl, adminToken) }

    val status by viewModel.status.collectAsStateWithLifecycle()
    val clients by viewModel.clients.collectAsStateWithLifecycle()
    val loading by viewModel.loading.collectAsStateWithLifecycle()
    val error by viewModel.error.collectAsStateWithLifecycle()
    val newConnString by viewModel.newConnString.collectAsStateWithLifecycle()

    var showAddDialog by remember { mutableStateOf(false) }
    var deleteConfirm by remember { mutableStateOf<String?>(null) }
    var searchQuery by remember { mutableStateOf("") }
    var activeFilter by remember { mutableStateOf(ClientFilter.ALL) }
    var showStatsDialog by remember { mutableStateOf<String?>(null) }
    var showSubDialog by remember { mutableStateOf<ClientInfo?>(null) }

    val filteredClients = clients.filter { c ->
        (searchQuery.isEmpty() || c.name.contains(searchQuery, ignoreCase = true)) &&
        when (activeFilter) {
            ClientFilter.ALL -> true
            ClientFilter.ONLINE -> c.connected
            ClientFilter.DISABLED -> !c.enabled
        }
    }

    // Dialogs
    if (newConnString != null) {
        ConnStringDialog(connString = newConnString!!, onDismiss = { viewModel.clearNewConnString() })
    }
    if (showAddDialog) {
        AddClientDialog(
            onConfirm = { name, days -> showAddDialog = false; viewModel.createClient(name, days) },
            onDismiss = { showAddDialog = false },
        )
    }
    deleteConfirm?.let { name ->
        AlertDialog(
            onDismissRequest = { deleteConfirm = null },
            title = { Text("Удалить клиента") },
            text = { Text("Удалить «$name»? Это действие нельзя отменить.") },
            confirmButton = {
                TextButton(onClick = { viewModel.deleteClient(name); deleteConfirm = null }) {
                    Text("Удалить", color = RedError)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteConfirm = null }) { Text("Отмена") }
            },
        )
    }
    showStatsDialog?.let { clientName ->
        val stats by viewModel.clientStats.collectAsStateWithLifecycle()
        val logs by viewModel.clientLogs.collectAsStateWithLifecycle()
        ClientDetailsDialog(
            clientName = clientName,
            stats = stats,
            logs = logs,
            onDismiss = { showStatsDialog = null; viewModel.clearClientDetails() },
        )
    }
    showSubDialog?.let { client ->
        SubscriptionDialog(
            client = client,
            onManage = { action, days -> viewModel.manageSubscription(client.name, action, days); showSubDialog = null },
            onDismiss = { showSubDialog = null },
        )
    }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Error banner
            if (error != null) {
                item {
                    Text(
                        error!!,
                        fontSize = 12.sp,
                        color = RedError,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(14.dp))
                            .background(RedError.copy(alpha = 0.1f))
                            .border(0.5.dp, RedError.copy(alpha = 0.22f), RoundedCornerShape(14.dp))
                            .padding(12.dp),
                    )
                }
            }

            // Hero card
            status?.let { s ->
                item { AdminHeroCard(status = s) }
            }

            // KPIs
            status?.let { s ->
                item {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        KpiCard("Аптайм", formatUptime(s.uptimeSecs), "uptime", Modifier.weight(1f))
                        KpiCard("Сессии", "${s.sessionsActive}", "active", Modifier.weight(1f))
                        KpiCard("Транспорт", "QUIC", "h3", Modifier.weight(1f))
                    }
                }
            }

            // Search
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(14.dp))
                        .background(Color.White.copy(alpha = 0.04f))
                        .border(0.5.dp, gc.cardBorder, RoundedCornerShape(14.dp))
                        .padding(12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Text("🔍", fontSize = 14.sp)
                    BasicTextField(
                        value = searchQuery,
                        onValueChange = { searchQuery = it },
                        singleLine = true,
                        textStyle = TextStyle(fontSize = 12.sp, color = gc.textPrimary),
                        cursorBrush = SolidColor(AccentPurple),
                        decorationBox = { inner ->
                            if (searchQuery.isEmpty()) Text("Поиск клиента...", fontSize = 12.sp, color = gc.textTertiary)
                            inner()
                        },
                        modifier = Modifier.weight(1f),
                    )
                    if (searchQuery.isNotEmpty()) {
                        Text(
                            "✕",
                            fontSize = 12.sp,
                            color = gc.textTertiary,
                            modifier = Modifier.clickable { searchQuery = "" },
                        )
                    }
                }
            }

            // Filter chips
            item {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    AdminFilterChip("Все (${clients.size})", activeFilter == ClientFilter.ALL) {
                        activeFilter = ClientFilter.ALL
                    }
                    AdminFilterChip("Онлайн (${clients.count { it.connected }})", activeFilter == ClientFilter.ONLINE) {
                        activeFilter = ClientFilter.ONLINE
                    }
                    AdminFilterChip("Отключены (${clients.count { !it.enabled }})", activeFilter == ClientFilter.DISABLED) {
                        activeFilter = ClientFilter.DISABLED
                    }
                }
            }

            // Section header
            item {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val countLabel = if (searchQuery.isEmpty() && activeFilter == ClientFilter.ALL)
                        "Клиенты" else "Результат"
                    Text(countLabel, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = gc.textPrimary)
                    Text(
                        "${filteredClients.size} из ${clients.size}",
                        fontSize = 11.sp,
                        color = gc.textTertiary,
                    )
                }
            }

            // Client cards
            if (filteredClients.isEmpty()) {
                item {
                    Text(
                        "Нет клиентов по заданным фильтрам.",
                        fontSize = 12.sp,
                        color = gc.textTertiary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(16.dp))
                            .border(0.5.dp, gc.cardBorder, RoundedCornerShape(16.dp))
                            .background(Color.White.copy(alpha = 0.03f))
                            .padding(20.dp),
                    )
                }
            }
            items(filteredClients, key = { it.name }) { client ->
                GlassClientCard(
                    client = client,
                    onToggle = { viewModel.toggleEnabled(client.name, client.enabled) },
                    onDelete = { deleteConfirm = client.name },
                    onCopyConnString = { viewModel.getConnString(client.name) },
                    onShowStats = {
                        showStatsDialog = client.name
                        viewModel.loadClientStats(client.name)
                        viewModel.loadClientLogs(client.name)
                    },
                    onSubscription = { showSubDialog = client },
                )
            }

            item { Spacer(Modifier.height(72.dp)) }
        }

        // FAB
        Box(
            modifier = Modifier
                .align(Alignment.BottomEnd)
                .padding(18.dp)
                .size(56.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(Brush.linearGradient(listOf(Color(0xFF7c6af7), Color(0xFFa855f7))))
                .clickable { showAddDialog = true },
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Add, "Добавить клиента", tint = Color.White, modifier = Modifier.size(24.dp))
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Sub-composables
// ═══════════════════════════════════════════════════════════════════════════

@Composable
private fun AdminHeroCard(status: ServerStatus) {
    val gc = LocalGhostColors.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(22.dp))
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        Color(0xFF7c6af7).copy(alpha = 0.22f),
                        Color(0xFF1a1c34).copy(alpha = 0.96f),
                        Color(0xFF0b0f1c).copy(alpha = 0.98f),
                    ),
                    start = Offset(0f, 0f),
                    end = Offset(600f, 400f),
                ),
            )
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(22.dp))
            .drawBehind {
                // Decorative teal circle top-right
                drawCircle(
                    color = Color(0xFF22d3a0).copy(alpha = 0.22f),
                    radius = 70f,
                    center = Offset(size.width + 34f, -52f),
                )
                // Decorative blue circle bottom-left
                drawCircle(
                    color = Color(0xFF60a5fa).copy(alpha = 0.16f),
                    radius = 60f,
                    center = Offset(-44f, size.height + 54f),
                )
            }
            .padding(18.dp),
    ) {
        Column {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.Top,
            ) {
                Column {
                    Text(
                        "Phantom VPN",
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.2.sp,
                        color = Color.White.copy(alpha = 0.56f),
                    )
                    Spacer(Modifier.height(6.dp))
                    Text("Сервер", fontSize = 20.sp, fontWeight = FontWeight.SemiBold, color = Color.White, letterSpacing = 0.2.sp)
                    Spacer(Modifier.height(6.dp))
                    Text(
                        "QUIC/H3 туннель, шифрование Noise IK",
                        fontSize = 11.sp,
                        color = Color.White.copy(alpha = 0.62f),
                        lineHeight = 15.5.sp,
                    )
                }
                // Status pill
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(AccentTeal.copy(alpha = 0.12f))
                        .border(0.5.dp, AccentTeal.copy(alpha = 0.26f), RoundedCornerShape(999.dp))
                        .padding(horizontal = 12.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Box(
                        Modifier
                            .size(7.dp)
                            .clip(CircleShape)
                            .background(Color(0xFF7af0cc)),
                    )
                    Text("Online", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF7af0cc))
                }
            }

            Spacer(Modifier.height(14.dp))
            // Divider
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(0.5.dp)
                    .background(Color.White.copy(alpha = 0.08f)),
            )
            Spacer(Modifier.height(12.dp))

            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Text("Вход", fontSize = 10.sp, letterSpacing = 1.sp, color = Color.White.copy(alpha = 0.5f))
                    Text(status.serverAddr, fontSize = 13.sp, fontFamily = FontFamily.Monospace, color = Color.White)
                }
                if (status.exitIp != null) {
                    Column(horizontalAlignment = Alignment.End) {
                        Text("Выход", fontSize = 10.sp, letterSpacing = 1.sp, color = Color.White.copy(alpha = 0.5f))
                        Text(status.exitIp, fontSize = 13.sp, fontFamily = FontFamily.Monospace, color = Color.White)
                    }
                }
            }
        }
    }
}

@Composable
private fun KpiCard(label: String, value: String, sub: String, modifier: Modifier = Modifier) {
    val gc = LocalGhostColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(18.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(18.dp))
            .padding(12.dp),
    ) {
        Text(label, fontSize = 10.sp, letterSpacing = 0.9.sp, color = gc.textTertiary)
        Spacer(Modifier.height(8.dp))
        Text(value, fontSize = 16.sp, fontFamily = FontFamily.Monospace, color = gc.textPrimary)
        Spacer(Modifier.height(4.dp))
        Text(sub, fontSize = 10.sp, color = gc.textTertiary)
    }
}

@Composable
private fun AdminFilterChip(text: String, isActive: Boolean, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    val bg = if (isActive) AccentPurple.copy(alpha = 0.16f) else Color.White.copy(alpha = 0.03f)
    val border = if (isActive) AccentPurple.copy(alpha = 0.34f) else gc.cardBorder
    val textColor = if (isActive) Color(0xFFe2ddff) else gc.textSecondary

    Text(
        text = text,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        color = textColor,
        modifier = Modifier
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

@Composable
private fun GlassClientCard(
    client: ClientInfo,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
    onCopyConnString: () -> Unit,
    onShowStats: () -> Unit,
    onSubscription: () -> Unit,
) {
    val gc = LocalGhostColors.current
    val nowSecs = System.currentTimeMillis() / 1000

    val subColor: Color? = client.expiresAt?.let { exp ->
        val daysLeft = (exp - nowSecs) / 86400
        when {
            daysLeft < 3 -> DangerRose
            daysLeft < 7 -> Color(0xFFFFA000)
            else -> AccentTeal
        }
    }
    val subLabel: String? = client.expiresAt?.let { exp ->
        val daysLeft = (exp - nowSecs) / 86400
        when {
            daysLeft < 0 -> "Истекла"
            daysLeft == 0L -> "< 1 дня"
            else -> "${daysLeft} дн."
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(18.dp))
            .background(
                Brush.verticalGradient(
                    listOf(Color.White.copy(alpha = 0.05f), Color.White.copy(alpha = 0.025f)),
                ),
            )
            .border(0.5.dp, gc.cardBorder, RoundedCornerShape(18.dp))
            .padding(14.dp),
    ) {
        // Main row: dot + name + tag
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Top,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.weight(1f),
            ) {
                // Client dot
                Box(
                    Modifier
                        .size(9.dp)
                        .clip(CircleShape)
                        .then(
                            if (client.connected)
                                Modifier
                                    .background(AccentPurple)
                                    .border(1.dp, AccentPurple.copy(alpha = 0.4f), CircleShape)
                            else
                                Modifier
                                    .border(1.dp, Color.White.copy(alpha = 0.35f), CircleShape),
                        ),
                )
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            client.name,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Medium,
                            color = gc.textPrimary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (client.connected) {
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "online",
                                fontSize = 10.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = Color(0xFF86efac),
                                modifier = Modifier
                                    .clip(RoundedCornerShape(999.dp))
                                    .background(AccentTeal.copy(alpha = 0.12f))
                                    .border(0.5.dp, AccentTeal.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
                                    .padding(horizontal = 8.dp, vertical = 3.dp),
                            )
                        }
                    }
                }
            }
            // Sub badge
            if (subLabel != null && subColor != null) {
                Text(
                    subLabel,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = subColor,
                    modifier = Modifier
                        .clip(RoundedCornerShape(999.dp))
                        .background(subColor.copy(alpha = 0.12f))
                        .border(0.5.dp, subColor.copy(alpha = 0.22f), RoundedCornerShape(999.dp))
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
        }

        Spacer(Modifier.height(5.dp))
        Text(client.tunAddr, fontSize = 11.sp, color = gc.textTertiary, fontFamily = FontFamily.Monospace)

        if (client.connected) {
            Spacer(Modifier.height(6.dp))
            Text(
                "↓ ${formatBytes(client.bytesRx)}  ↑ ${formatBytes(client.bytesTx)}  · ${client.lastSeenSecs}s ago",
                fontSize = 11.sp,
                color = gc.textTertiary,
            )
        }
        if (!client.enabled) {
            Spacer(Modifier.height(4.dp))
            Text("Отключён", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = RedError)
        }

        Spacer(Modifier.height(10.dp))

        // Actions row
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ClientAction("⏻") { onToggle() }
            ClientAction("📋") { onCopyConnString() }
            ClientAction("📊") { onShowStats() }
            ClientAction("⏱") { onSubscription() }
            ClientAction("🗑", isDanger = true) { onDelete() }
        }
    }
}

@Composable
private fun ClientAction(icon: String, isDanger: Boolean = false, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    Text(
        icon,
        fontSize = 16.sp,
        modifier = Modifier
            .clickable(onClick = onClick)
            .padding(4.dp),
    )
}

@Composable
private fun AddClientDialog(onConfirm: (String, Int?) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var daysText by remember { mutableStateOf("30") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Новый клиент") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val gc = LocalGhostColors.current
                BasicTextField(
                    value = name,
                    onValueChange = { name = it },
                    singleLine = true,
                    textStyle = TextStyle(fontSize = 13.sp, color = gc.textPrimary),
                    cursorBrush = SolidColor(AccentPurple),
                    decorationBox = { inner ->
                        Column {
                            Text("Имя (a-z, 0-9, дефис)", fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp, color = gc.textTertiary)
                            Spacer(Modifier.height(6.dp))
                            Box(
                                Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color.White.copy(alpha = 0.04f))
                                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                                    .padding(12.dp),
                            ) {
                                if (name.isEmpty()) Text("alice", fontSize = 13.sp, color = gc.textTertiary.copy(alpha = 0.5f))
                                inner()
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                BasicTextField(
                    value = daysText,
                    onValueChange = { daysText = it.filter { c -> c.isDigit() }.take(4) },
                    singleLine = true,
                    textStyle = TextStyle(fontSize = 13.sp, color = gc.textPrimary),
                    cursorBrush = SolidColor(AccentPurple),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    decorationBox = { inner ->
                        Column {
                            Text("Дней подписки (пусто = бессрочно)", fontSize = 10.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp, color = gc.textTertiary)
                            Spacer(Modifier.height(6.dp))
                            Box(
                                Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color.White.copy(alpha = 0.04f))
                                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                                    .padding(12.dp),
                            ) {
                                if (daysText.isEmpty()) Text("∞", fontSize = 13.sp, color = gc.textTertiary.copy(alpha = 0.5f))
                                inner()
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onConfirm(name.trim(), daysText.toIntOrNull()) }, enabled = name.isNotBlank()) {
                Text("Создать")
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Отмена") } },
    )
}

@Composable
private fun ClientDetailsDialog(
    clientName: String,
    stats: List<StatsSample>,
    logs: List<DestEntry>,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(clientName) },
        text = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item { Text("Трафик (последний час)", fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
                if (stats.isEmpty()) {
                    item { Text("Нет данных", fontSize = 11.sp, color = LocalGhostColors.current.textTertiary) }
                } else {
                    item {
                        Text(
                            "↓ ${formatBytes(stats.last().bytesRx)} total  ↑ ${formatBytes(stats.last().bytesTx)} total",
                            fontSize = 11.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
                item { Spacer(Modifier.height(8.dp)); Text("Последние подключения (${logs.size})", fontSize = 12.sp, fontWeight = FontWeight.SemiBold) }
                if (logs.isEmpty()) {
                    item { Text("Нет записей", fontSize = 11.sp, color = LocalGhostColors.current.textTertiary) }
                } else {
                    items(logs.take(50)) { entry ->
                        Text(
                            "${entry.proto.uppercase()}  ${entry.dst}:${entry.port}  ${formatBytes(entry.bytes)}",
                            fontSize = 10.sp,
                            fontFamily = FontFamily.Monospace,
                        )
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Закрыть") } },
    )
}

@Composable
private fun SubscriptionDialog(
    client: ClientInfo,
    onManage: (action: String, days: Int?) -> Unit,
    onDismiss: () -> Unit,
) {
    val gc = LocalGhostColors.current
    val nowSecs = System.currentTimeMillis() / 1000
    val currentStatus = client.expiresAt?.let { exp ->
        val daysLeft = (exp - nowSecs) / 86400
        when {
            daysLeft < 0 -> "Истекла"
            daysLeft == 0L -> "Истекает сегодня"
            else -> "Активна ещё ${daysLeft} дн."
        }
    } ?: "Бессрочная"

    var customDays by remember { mutableStateOf("") }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Подписка: ${client.name}") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(
                    "Статус: $currentStatus",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    color = client.expiresAt?.let { exp ->
                        val d = (exp - nowSecs) / 86400
                        when {
                            d < 0 -> RedError
                            d < 7 -> Color(0xFFFFA000)
                            else -> AccentTeal
                        }
                    } ?: AccentPurple,
                )
                Box(Modifier.fillMaxWidth().height(0.5.dp).background(gc.cardBorder))
                Text("Продлить:", fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = gc.textTertiary)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SubActionButton("+30 дн.", Modifier.weight(1f)) { onManage("extend", 30) }
                    SubActionButton("+90 дн.", Modifier.weight(1f)) { onManage("extend", 90) }
                    SubActionButton("+1 год", Modifier.weight(1f)) { onManage("extend", 365) }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    BasicTextField(
                        value = customDays,
                        onValueChange = { customDays = it.filter { c -> c.isDigit() }.take(4) },
                        singleLine = true,
                        textStyle = TextStyle(fontSize = 13.sp, color = gc.textPrimary),
                        cursorBrush = SolidColor(AccentPurple),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        decorationBox = { inner ->
                            Box(
                                Modifier
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(Color.White.copy(alpha = 0.04f))
                                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                                    .padding(12.dp),
                            ) {
                                if (customDays.isEmpty()) Text("Дней", fontSize = 13.sp, color = gc.textTertiary.copy(alpha = 0.5f))
                                inner()
                            }
                        },
                        modifier = Modifier.weight(1f),
                    )
                    SubActionButton("Установить") {
                        customDays.toIntOrNull()?.let { onManage("set", it) }
                    }
                }
                Box(Modifier.fillMaxWidth().height(0.5.dp).background(gc.cardBorder))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    SubActionButton("Бессрочно", Modifier.weight(1f)) { onManage("cancel", null) }
                    Text(
                        "Аннулировать",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = Color.White,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(RedError)
                            .clickable { onManage("revoke", null) }
                            .padding(10.dp),
                    )
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Закрыть") } },
    )
}

@Composable
private fun SubActionButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    Text(
        text = text,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        color = gc.textSecondary,
        textAlign = TextAlign.Center,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(10.dp),
    )
}

@Composable
private fun ConnStringDialog(connString: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    val qrBitmap = remember(connString) {
        runCatching {
            val size = 512
            val bits = QRCodeWriter().encode(connString, BarcodeFormat.QR_CODE, size, size)
            val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.RGB_565)
            for (x in 0 until size) for (y in 0 until size) {
                bmp.setPixel(x, y, if (bits[x, y]) android.graphics.Color.BLACK else android.graphics.Color.WHITE)
            }
            bmp.asImageBitmap()
        }.getOrNull()
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Строка подключения") },
        text = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                qrBitmap?.let { bm ->
                    Image(bitmap = bm, contentDescription = "QR", modifier = Modifier.size(200.dp))
                }
                Text("Скопируйте и вставьте в приложение PhantomVPN:", fontSize = 11.sp, color = LocalGhostColors.current.textSecondary)
                Text(
                    connString.take(120) + if (connString.length > 120) "…" else "",
                    fontSize = 10.sp,
                    fontFamily = FontFamily.Monospace,
                    color = LocalGhostColors.current.textTertiary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(8.dp))
                        .background(Color.White.copy(alpha = 0.04f))
                        .padding(8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("conn_string", connString))
                onDismiss()
            }) { Text("Скопировать") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Закрыть") } },
    )
}

private fun formatUptime(secs: Long): String {
    val h = secs / 3600
    val m = (secs % 3600) / 60
    val s = secs % 60
    return if (h > 0) "${h}ч ${m}м" else if (m > 0) "${m}м ${s}с" else "${s}с"
}
