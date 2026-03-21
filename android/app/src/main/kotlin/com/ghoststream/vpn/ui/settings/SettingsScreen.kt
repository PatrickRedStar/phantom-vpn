package com.ghoststream.vpn.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.ui.theme.TextSecondary

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel = viewModel(),
    onNavigateToQrScanner: () -> Unit = {},
) {
    val config by viewModel.config.collectAsStateWithLifecycle()
    val connString by viewModel.connString.collectAsStateWithLifecycle()
    val importStatus by viewModel.importStatus.collectAsStateWithLifecycle()
    val theme by viewModel.theme.collectAsStateWithLifecycle()
    val clipboardManager = LocalClipboardManager.current

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        contentPadding = PaddingValues(vertical = 16.dp),
    ) {
        // ── Profile ──────────────────────────────────────────────
        item {
            SettingsSection("Профиль подключения") {
                OutlinedTextField(
                    value = connString,
                    onValueChange = { viewModel.setConnString(it) },
                    label = { Text("Строка подключения") },
                    modifier = Modifier.fillMaxWidth(),
                    textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp),
                    minLines = 3,
                    maxLines = 5,
                )
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = {
                            clipboardManager.getText()?.text?.let { viewModel.setConnString(it) }
                        },
                        modifier = Modifier.weight(1f),
                    ) { Text("Из буфера") }
                    OutlinedButton(
                        onClick = onNavigateToQrScanner,
                        modifier = Modifier.weight(1f),
                    ) { Text("QR-код") }
                }
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = { viewModel.importConfig() },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Применить") }
                if (importStatus.isNotEmpty()) {
                    Spacer(Modifier.height(4.dp))
                    Text(importStatus, style = MaterialTheme.typography.bodySmall)
                }
                if (config.serverAddr.isNotBlank()) {
                    Spacer(Modifier.height(12.dp))
                    ConfigRow("Сервер", config.serverAddr)
                    ConfigRow("SNI", config.serverName)
                    ConfigRow("TUN", config.tunAddr)
                    ConfigRow("Сертификат", if (config.certPath.isNotBlank()) "настроен" else "нет")
                    ConfigRow("Ключ", if (config.keyPath.isNotBlank()) "настроен" else "нет")
                }
            }
        }

        // ── DNS ──────────────────────────────────────────────────
        item {
            var showAddDialog by remember { mutableStateOf(false) }
            var newDns by remember { mutableStateOf("") }

            SettingsSection("DNS серверы") {
                config.dnsServers.forEachIndexed { index, dns ->
                    Row(
                        Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            dns,
                            modifier = Modifier.weight(1f),
                            fontFamily = FontFamily.Monospace,
                        )
                        IconButton(onClick = {
                            viewModel.setDnsServers(
                                config.dnsServers.toMutableList().also { it.removeAt(index) },
                            )
                        }) { Icon(Icons.Filled.Close, "Удалить") }
                    }
                }
                OutlinedButton(onClick = { showAddDialog = true }) {
                    Icon(Icons.Filled.Add, null)
                    Spacer(Modifier.width(4.dp))
                    Text("Добавить")
                }
                Spacer(Modifier.height(8.dp))
                Text("Пресеты:", style = MaterialTheme.typography.labelSmall, color = TextSecondary)
                Spacer(Modifier.height(4.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    listOf(
                        "Google" to listOf("8.8.8.8", "8.8.4.4"),
                        "Cloudflare" to listOf("1.1.1.1", "1.0.0.1"),
                        "AdGuard" to listOf("94.140.14.14", "94.140.15.15"),
                        "Quad9" to listOf("9.9.9.9"),
                    ).forEach { (name, servers) ->
                        AssistChip(
                            onClick = { viewModel.setDnsServers(servers) },
                            label = { Text(name, fontSize = 12.sp) },
                        )
                    }
                }
            }

            if (showAddDialog) {
                AlertDialog(
                    onDismissRequest = { showAddDialog = false },
                    title = { Text("Добавить DNS") },
                    text = {
                        OutlinedTextField(
                            value = newDns,
                            onValueChange = { newDns = it },
                            label = { Text("IP адрес") },
                            singleLine = true,
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            if (newDns.isNotBlank()) {
                                viewModel.setDnsServers(config.dnsServers + newDns.trim())
                                newDns = ""
                                showAddDialog = false
                            }
                        }) { Text("Добавить") }
                    },
                    dismissButton = {
                        TextButton(onClick = { showAddDialog = false }) { Text("Отмена") }
                    },
                )
            }
        }

        // ── Network ──────────────────────────────────────────────
        item {
            SettingsSection("Сеть") {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Пропускать проверку TLS")
                        Text(
                            "Для серверов без mTLS-сертификата",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                    }
                    Switch(
                        checked = config.insecure,
                        onCheckedChange = { viewModel.setInsecure(it) },
                    )
                }
            }
        }

        // ── Routing ────────────────────────────────────────────────
        item {
            val downloadStatus by viewModel.downloadStatus.collectAsStateWithLifecycle()

            SettingsSection("Маршрутизация") {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Раздельная маршрутизация")
                        Text(
                            "Трафик к выбранным странам идёт напрямую",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                    }
                    Switch(
                        checked = config.splitRouting,
                        onCheckedChange = { viewModel.setSplitRouting(it) },
                    )
                }

                if (config.splitRouting) {
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Страны (напрямую):",
                        style = MaterialTheme.typography.labelSmall,
                        color = TextSecondary,
                    )
                    Spacer(Modifier.height(4.dp))
                    RoutingRulesManager.AVAILABLE_COUNTRIES.forEach { (code, label) ->
                        val isSelected = code in config.directCountries
                        val isDownloaded = viewModel.routingRulesManager.isDownloaded(code)
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clickable { viewModel.toggleDirectCountry(code) }
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(
                                checked = isSelected,
                                onCheckedChange = { viewModel.toggleDirectCountry(code) },
                            )
                            Spacer(Modifier.width(4.dp))
                            Column(Modifier.weight(1f)) {
                                Text(label)
                                if (!isDownloaded) {
                                    Text(
                                        "не загружен",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = TextSecondary,
                                    )
                                }
                            }
                            if (!isDownloaded || isSelected) {
                                IconButton(onClick = { viewModel.downloadCountryRules(code) }) {
                                    Icon(Icons.Filled.Download, "Загрузить")
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Button(
                        onClick = { viewModel.downloadAllSelected() },
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Обновить списки") }
                    if (downloadStatus.isNotBlank()) {
                        Spacer(Modifier.height(4.dp))
                        Text(downloadStatus, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }

        // ── Per-app ───────────────────────────────────────────────
        item {
            SettingsSection("Приложения") {
                listOf(
                    "none" to "Все через VPN",
                    "disallowed" to "Все, кроме выбранных",
                    "allowed" to "Только выбранные",
                ).forEach { (value, label) ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { viewModel.setPerAppMode(value) }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = config.perAppMode == value,
                            onClick = { viewModel.setPerAppMode(value) },
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(label)
                    }
                }

                if (config.perAppMode != "none") {
                    var showAppPicker by remember { mutableStateOf(false) }
                    Spacer(Modifier.height(8.dp))
                    if (config.perAppList.isNotEmpty()) {
                        Text(
                            "${config.perAppList.size} приложений выбрано",
                            style = MaterialTheme.typography.bodySmall,
                            color = TextSecondary,
                        )
                        Spacer(Modifier.height(4.dp))
                    }
                    OutlinedButton(onClick = {
                        viewModel.loadInstalledApps()
                        showAppPicker = true
                    }) { Text("Выбрать приложения") }

                    if (showAppPicker) {
                        val apps by viewModel.installedApps.collectAsStateWithLifecycle()
                        var search by remember { mutableStateOf("") }
                        AlertDialog(
                            onDismissRequest = { showAppPicker = false },
                            title = { Text("Приложения") },
                            text = {
                                Column {
                                    OutlinedTextField(
                                        value = search,
                                        onValueChange = { search = it },
                                        label = { Text("Поиск") },
                                        singleLine = true,
                                        modifier = Modifier.fillMaxWidth(),
                                    )
                                    Spacer(Modifier.height(8.dp))
                                    val filtered = apps.filter {
                                        !it.isSystem && (search.isBlank() ||
                                            it.label.contains(search, ignoreCase = true) ||
                                            it.packageName.contains(search, ignoreCase = true))
                                    }
                                    LazyColumn {
                                        items(filtered, key = { it.packageName }) { app ->
                                            Row(
                                                Modifier
                                                    .fillMaxWidth()
                                                    .clickable { viewModel.togglePerApp(app.packageName) }
                                                    .padding(vertical = 4.dp),
                                                verticalAlignment = Alignment.CenterVertically,
                                            ) {
                                                Checkbox(
                                                    checked = app.packageName in config.perAppList,
                                                    onCheckedChange = { viewModel.togglePerApp(app.packageName) },
                                                )
                                                Spacer(Modifier.width(8.dp))
                                                Column {
                                                    Text(app.label, maxLines = 1)
                                                    Text(
                                                        app.packageName,
                                                        style = MaterialTheme.typography.bodySmall,
                                                        color = TextSecondary,
                                                        maxLines = 1,
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            },
                            confirmButton = {
                                TextButton(onClick = { showAppPicker = false }) { Text("Готово") }
                            },
                        )
                    }
                }
            }
        }

        // ── Theme ────────────────────────────────────────────────
        item {
            SettingsSection("Интерфейс") {
                listOf(
                    "system" to "Системная",
                    "dark" to "Тёмная",
                    "light" to "Светлая",
                ).forEach { (value, label) ->
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable { viewModel.setTheme(value) }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(
                            selected = theme == value,
                            onClick = { viewModel.setTheme(value) },
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(label)
                    }
                }
            }
        }

        // ── About ────────────────────────────────────────────────
        item {
            SettingsSection("О приложении") {
                Text("GhostStream VPN", style = MaterialTheme.typography.titleMedium)
                Text(
                    "Версия 1.0",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                )
            }
        }
    }
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        ),
        shape = RoundedCornerShape(16.dp),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(bottom = 12.dp),
            )
            content()
        }
    }
}

@Composable
private fun ConfigRow(label: String, value: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 2.dp),
    ) {
        Text("$label: ", style = MaterialTheme.typography.bodySmall, color = TextSecondary)
        Text(
            value,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
        )
    }
}
