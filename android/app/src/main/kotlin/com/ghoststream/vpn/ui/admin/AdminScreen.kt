package com.ghoststream.vpn.ui.admin

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

enum class ClientFilter { ALL, ONLINE, DISABLED }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdminScreen(
    adminUrl: String,
    adminToken: String,
    onBack: () -> Unit,
    viewModel: AdminViewModel = viewModel(),
) {
    LaunchedEffect(adminUrl, adminToken) {
        viewModel.init(adminUrl, adminToken)
    }

    val status by viewModel.status.collectAsStateWithLifecycle()
    val clients by viewModel.clients.collectAsStateWithLifecycle()
    val loading by viewModel.loading.collectAsStateWithLifecycle()
    val error by viewModel.error.collectAsStateWithLifecycle()
    val newConnString by viewModel.newConnString.collectAsStateWithLifecycle()

    var showAddDialog by remember { mutableStateOf(false) }
    var deleteConfirm by remember { mutableStateOf<String?>(null) }
    var toggleConfirm by remember { mutableStateOf<ClientInfo?>(null) }
    var searchQuery by remember { mutableStateOf("") }
    var activeFilter by remember { mutableStateOf(ClientFilter.ALL) }
    var showStatsDialog by remember { mutableStateOf<String?>(null) }
    var showSubDialog by remember { mutableStateOf<ClientInfo?>(null) }

    val filteredClients = clients
        .filter { c ->
            (searchQuery.isEmpty() || c.name.contains(searchQuery, ignoreCase = true)) &&
            when (activeFilter) {
                ClientFilter.ALL      -> true
                ClientFilter.ONLINE   -> c.connected
                ClientFilter.DISABLED -> !c.enabled
            }
        }

    // Show conn string dialog when a new client is created or conn string is fetched
    if (newConnString != null) {
        ConnStringDialog(
            connString = newConnString!!,
            onDismiss = { viewModel.clearNewConnString() },
        )
    }

    if (showAddDialog) {
        AddClientDialog(
            onConfirm = { name, days ->
                showAddDialog = false
                viewModel.createClient(name, days)
            },
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
                    Text("Удалить", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { deleteConfirm = null }) { Text("Отмена") }
            },
        )
    }

    toggleConfirm?.let { client ->
        val action = if (client.enabled) "отключить" else "включить"
        AlertDialog(
            onDismissRequest = { toggleConfirm = null },
            title = { Text("${action.replaceFirstChar { it.uppercase() }} клиента?") },
            text = {
                Text(
                    if (client.enabled)
                        "Клиент «${client.name}» будет отключён. Текущая сессия сохранится, но повторное подключение будет невозможно."
                    else
                        "Клиент «${client.name}» будет включён и сможет подключаться.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.toggleEnabled(client.name, client.enabled)
                    toggleConfirm = null
                }) { Text(action.replaceFirstChar { it.uppercase() }) }
            },
            dismissButton = {
                TextButton(onClick = { toggleConfirm = null }) { Text("Отмена") }
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
            onDismiss = {
                showStatsDialog = null
                viewModel.clearClientDetails()
            },
        )
    }

    showSubDialog?.let { client ->
        SubscriptionDialog(
            client = client,
            onManage = { action, days ->
                viewModel.manageSubscription(client.name, action, days)
                showSubDialog = null
            },
            onDismiss = { showSubDialog = null },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Администрирование") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.Filled.ArrowBack, null)
                    }
                },
                actions = {
                    if (loading) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp).padding(end = 8.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        IconButton(onClick = { viewModel.refresh() }) {
                            Icon(Icons.Filled.Refresh, "Обновить")
                        }
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = { showAddDialog = true }) {
                Icon(Icons.Filled.PersonAdd, "Добавить клиента")
            }
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(padding),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Error banner with retry
            if (error != null) {
                item {
                    Card(
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Column(Modifier.padding(12.dp)) {
                            Text(
                                error!!,
                                color = MaterialTheme.colorScheme.onErrorContainer,
                            )
                            Spacer(Modifier.height(8.dp))
                            TextButton(onClick = { viewModel.refresh() }) {
                                Text("Повторить")
                            }
                        }
                    }
                }
            }

            // Search bar
            item {
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    label = { Text("Поиск клиента") },
                    leadingIcon = { Icon(Icons.Filled.Search, null) },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }) {
                                Icon(Icons.Filled.Clear, null)
                            }
                        }
                    },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // Filter chips
            item {
                Row(
                    modifier = Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    FilterChip(
                        selected = activeFilter == ClientFilter.ALL,
                        onClick = { activeFilter = ClientFilter.ALL },
                        label = { Text("Все (${clients.size})") },
                    )
                    FilterChip(
                        selected = activeFilter == ClientFilter.ONLINE,
                        onClick = { activeFilter = ClientFilter.ONLINE },
                        label = { Text("Онлайн (${clients.count { it.connected }})") },
                    )
                    FilterChip(
                        selected = activeFilter == ClientFilter.DISABLED,
                        onClick = { activeFilter = ClientFilter.DISABLED },
                        label = { Text("Отключены (${clients.count { !it.enabled }})") },
                    )
                }
            }

            // Server status card
            status?.let { s ->
                item {
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("Сервер", style = MaterialTheme.typography.titleMedium)
                            Text("Вход: ${s.serverAddr}", style = MaterialTheme.typography.bodySmall)
                            if (s.exitIp != null) {
                                Text("Выход: ${s.exitIp}", style = MaterialTheme.typography.bodySmall)
                            }
                            Text("Аптайм: ${formatUptime(s.uptimeSecs)}", style = MaterialTheme.typography.bodySmall)
                            Text("Активных сессий: ${s.sessionsActive}", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }

            // Clients header
            item {
                val countLabel = if (searchQuery.isEmpty() && activeFilter == ClientFilter.ALL)
                    "Клиенты (${clients.size})"
                else
                    "Клиенты (${filteredClients.size} из ${clients.size})"
                Text(
                    countLabel,
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(vertical = 4.dp),
                )
            }

            items(filteredClients, key = { it.name }) { client ->
                ClientCard(
                    client = client,
                    onToggle = { toggleConfirm = client },
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
        }
    }
}

@Composable
private fun ClientCard(
    client: ClientInfo,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
    onCopyConnString: () -> Unit,
    onShowStats: () -> Unit = {},
    onSubscription: () -> Unit = {},
) {
    val nowSecs = System.currentTimeMillis() / 1000
    val subColor: Color? = client.expiresAt?.let { exp ->
        val daysLeft = (exp - nowSecs) / 86400
        when {
            daysLeft < 0  -> Color(0xFFE53935)
            daysLeft < 3  -> Color(0xFFE53935)
            daysLeft < 7  -> Color(0xFFFFA000)
            else          -> Color(0xFF43A047)
        }
    }
    val subLabel: String? = client.expiresAt?.let { exp ->
        val daysLeft = (exp - nowSecs) / 86400
        when {
            daysLeft < 0  -> "Подписка истекла"
            daysLeft == 0L -> "Менее суток"
            else          -> "${daysLeft} дн."
        }
    }

    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = if (!client.enabled)
                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
            else MaterialTheme.colorScheme.surface,
        ),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                // Connected dot
                Icon(
                    if (client.connected) Icons.Filled.Circle else Icons.Filled.RadioButtonUnchecked,
                    null,
                    tint = if (client.connected) MaterialTheme.colorScheme.primary
                           else MaterialTheme.colorScheme.outline,
                    modifier = Modifier.size(12.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(client.name, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
                // Subscription badge
                if (subLabel != null && subColor != null) {
                    Surface(
                        color = subColor.copy(alpha = 0.15f),
                        shape = MaterialTheme.shapes.extraSmall,
                    ) {
                        Text(
                            subLabel,
                            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
                            style = MaterialTheme.typography.labelSmall,
                            color = subColor,
                        )
                    }
                    Spacer(Modifier.width(4.dp))
                }
                // Subscription management
                IconButton(onClick = onSubscription, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.CardMembership, "Подписка", modifier = Modifier.size(18.dp))
                }
                // Toggle enabled
                IconButton(onClick = onToggle, modifier = Modifier.size(32.dp)) {
                    Icon(
                        if (client.enabled) Icons.Filled.ToggleOn else Icons.Filled.ToggleOff,
                        if (client.enabled) "Отключить" else "Включить",
                        tint = if (client.enabled) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.outline,
                    )
                }
                // Copy conn string
                IconButton(onClick = onCopyConnString, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.QrCode, "Строка подключения", modifier = Modifier.size(18.dp))
                }
                // Stats / logs
                IconButton(onClick = onShowStats, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.QueryStats, "Статистика", modifier = Modifier.size(18.dp))
                }
                // Delete
                IconButton(onClick = onDelete, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Filled.DeleteOutline, "Удалить", tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(18.dp))
                }
            }
            Spacer(Modifier.height(4.dp))
            Text(client.tunAddr, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline)
            if (client.connected) {
                Text(
                    "↓ ${formatBytes(client.bytesRx)}  ↑ ${formatBytes(client.bytesTx)}  · ${client.lastSeenSecs}s ago",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.outline,
                )
            }
            if (!client.enabled) {
                Text("Отключён", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.error)
            }
        }
    }
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
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text("Имя (a-z, 0-9, дефис)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = daysText,
                    onValueChange = { daysText = it.filter { c -> c.isDigit() }.take(4) },
                    label = { Text("Дней подписки (пусто = бессрочно)") },
                    placeholder = { Text("∞") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name.trim(), daysText.toIntOrNull()) },
                enabled = name.isNotBlank(),
            ) { Text("Создать") }
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
            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                // Stats section
                item {
                    Text("Трафик (последний час)", style = MaterialTheme.typography.titleSmall)
                }
                if (stats.isEmpty()) {
                    item { Text("Нет данных (клиент не подключён или нет истории)", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline) }
                } else {
                    item {
                        val maxRx = stats.maxOf { it.bytesRx }.coerceAtLeast(1)
                        val maxTx = stats.maxOf { it.bytesTx }.coerceAtLeast(1)
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("↓ ${formatBytes(stats.last().bytesRx)} total  ↑ ${formatBytes(stats.last().bytesTx)} total", style = MaterialTheme.typography.bodySmall)
                            // Simple sparkline (last 12 samples)
                            val recent = stats.takeLast(12)
                            Canvas(modifier = Modifier.fillMaxWidth().height(48.dp)) {
                                val w = size.width / recent.size
                                recent.forEachIndexed { i, s ->
                                    val rxH = (s.bytesRx.toFloat() / maxRx * size.height * 0.9f).coerceAtLeast(2f)
                                    val txH = (s.bytesTx.toFloat() / maxTx * size.height * 0.9f).coerceAtLeast(2f)
                                    drawRect(color = Color(0xFF4CAF50), topLeft = Offset(i * w, size.height - rxH), size = Size(w * 0.4f, rxH))
                                    drawRect(color = Color(0xFF2196F3), topLeft = Offset(i * w + w * 0.5f, size.height - txH), size = Size(w * 0.4f, txH))
                                }
                            }
                            Row {
                                Text("■ ↓ RX  ", style = MaterialTheme.typography.labelSmall, color = Color(0xFF4CAF50))
                                Text("■ ↑ TX", style = MaterialTheme.typography.labelSmall, color = Color(0xFF2196F3))
                            }
                        }
                    }
                }
                // Logs section
                item {
                    Spacer(Modifier.height(8.dp))
                    Text("Последние подключения (${logs.size})", style = MaterialTheme.typography.titleSmall)
                }
                if (logs.isEmpty()) {
                    item { Text("Нет записей", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.outline) }
                } else {
                    items(logs.take(50)) { entry ->
                        Text(
                            "${entry.proto.uppercase()}  ${entry.dst}:${entry.port}  ${formatBytes(entry.bytes)}",
                            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
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
    val nowSecs = System.currentTimeMillis() / 1000
    val currentStatus: String = client.expiresAt?.let { exp ->
        val daysLeft = (exp - nowSecs) / 86400
        when {
            daysLeft < 0  -> "Истекла"
            daysLeft == 0L -> "Истекает сегодня"
            else          -> "Активна ещё ${daysLeft} дн."
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
                    style = MaterialTheme.typography.bodyMedium,
                    color = client.expiresAt?.let { exp ->
                        val d = (exp - nowSecs) / 86400
                        when {
                            d < 0 -> MaterialTheme.colorScheme.error
                            d < 7 -> Color(0xFFFFA000)
                            else  -> Color(0xFF43A047)
                        }
                    } ?: MaterialTheme.colorScheme.primary,
                )
                Divider()
                Text("Продлить:", style = MaterialTheme.typography.labelMedium)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { onManage("extend", 30) }, modifier = Modifier.weight(1f)) {
                        Text("+30 дн.", style = MaterialTheme.typography.labelSmall)
                    }
                    OutlinedButton(onClick = { onManage("extend", 90) }, modifier = Modifier.weight(1f)) {
                        Text("+90 дн.", style = MaterialTheme.typography.labelSmall)
                    }
                    OutlinedButton(onClick = { onManage("extend", 365) }, modifier = Modifier.weight(1f)) {
                        Text("+1 год", style = MaterialTheme.typography.labelSmall)
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        value = customDays,
                        onValueChange = { customDays = it.filter { c -> c.isDigit() }.take(4) },
                        label = { Text("Дней") },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        modifier = Modifier.weight(1f),
                    )
                    Button(
                        onClick = { customDays.toIntOrNull()?.let { onManage("set", it) } },
                        enabled = customDays.toIntOrNull() != null,
                    ) { Text("Установить") }
                }
                Divider()
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = { onManage("cancel", null) },
                        modifier = Modifier.weight(1f),
                    ) { Text("Бессрочно", style = MaterialTheme.typography.labelSmall) }
                    Button(
                        onClick = { onManage("revoke", null) },
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error),
                        modifier = Modifier.weight(1f),
                    ) { Text("Аннулировать", style = MaterialTheme.typography.labelSmall) }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Закрыть") } },
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
                    Image(
                        bitmap = bm,
                        contentDescription = "QR-код строки подключения",
                        modifier = Modifier.size(200.dp),
                    )
                }
                Text("Скопируйте и вставьте в приложение PhantomVPN:", style = MaterialTheme.typography.bodySmall)
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = MaterialTheme.shapes.small,
                ) {
                    Text(
                        connString.take(120) + if (connString.length > 120) "…" else "",
                        modifier = Modifier.padding(8.dp),
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    )
                }
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
