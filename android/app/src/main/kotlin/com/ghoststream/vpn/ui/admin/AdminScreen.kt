package com.ghoststream.vpn.ui.admin

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

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

    // Show conn string dialog when a new client is created or conn string is fetched
    if (newConnString != null) {
        ConnStringDialog(
            connString = newConnString!!,
            onDismiss = { viewModel.clearNewConnString() },
        )
    }

    if (showAddDialog) {
        AddClientDialog(
            onConfirm = { name ->
                showAddDialog = false
                viewModel.createClient(name)
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
            // Error banner
            if (error != null) {
                item {
                    Card(
                        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            error!!,
                            modifier = Modifier.padding(12.dp),
                            color = MaterialTheme.colorScheme.onErrorContainer,
                        )
                    }
                }
            }

            // Server status card
            status?.let { s ->
                item {
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("Сервер", style = MaterialTheme.typography.titleMedium)
                            Text("Адрес: ${s.serverAddr}", style = MaterialTheme.typography.bodySmall)
                            Text("Аптайм: ${formatUptime(s.uptimeSecs)}", style = MaterialTheme.typography.bodySmall)
                            Text("Активных сессий: ${s.sessionsActive}", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }
            }

            // Clients header
            item {
                Text(
                    "Клиенты (${clients.size})",
                    style = MaterialTheme.typography.titleMedium,
                    modifier = Modifier.padding(vertical = 4.dp),
                )
            }

            items(clients, key = { it.name }) { client ->
                ClientCard(
                    client = client,
                    onToggle = { viewModel.toggleEnabled(client.name, client.enabled) },
                    onDelete = { deleteConfirm = client.name },
                    onCopyConnString = { viewModel.getConnString(client.name) },
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
) {
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
private fun AddClientDialog(onConfirm: (String) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Новый клиент") },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                label = { Text("Имя (a-z, 0-9, дефис)") },
                singleLine = true,
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(name.trim()) },
                enabled = name.isNotBlank(),
            ) { Text("Создать") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Отмена") } },
    )
}

@Composable
private fun ConnStringDialog(connString: String, onDismiss: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Строка подключения") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
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
