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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AdminPanelSettings
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.Cast
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.NetworkCheck
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.data.RoutingRulesManager
import com.ghoststream.vpn.data.VpnProfile
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.RedError
import com.ghoststream.vpn.ui.theme.TextSecondary
import com.ghoststream.vpn.ui.theme.YellowWarning

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel = viewModel(),
    onNavigateToQrScanner: () -> Unit = {},
    onAdminNavigate: (String) -> Unit = {},
    onShareToTv: (profileId: String) -> Unit = {},
    onGetFromPhone: () -> Unit = {},
) {
    val config by viewModel.config.collectAsStateWithLifecycle()
    val profiles by viewModel.profiles.collectAsStateWithLifecycle()
    val activeProfileId by viewModel.activeProfileId.collectAsStateWithLifecycle()
    val pendingConnString by viewModel.pendingConnString.collectAsStateWithLifecycle()
    val pendingName by viewModel.pendingName.collectAsStateWithLifecycle()
    val importStatus by viewModel.importStatus.collectAsStateWithLifecycle()
    val theme by viewModel.theme.collectAsStateWithLifecycle()
    val pingResults by viewModel.pingResults.collectAsStateWithLifecycle()
    val pinging by viewModel.pinging.collectAsStateWithLifecycle()
    val profileSubscriptions by viewModel.profileSubscriptions.collectAsStateWithLifecycle()
    val sendToTvStatus by viewModel.sendToTvStatus.collectAsStateWithLifecycle()
    val clipboardManager = LocalClipboardManager.current
    val context = LocalContext.current
    val isAndroidTv = remember {
        context.packageManager.hasSystemFeature("android.software.leanback")
    }
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(sendToTvStatus) {
        val msg = sendToTvStatus ?: return@LaunchedEffect
        snackbarHostState.showSnackbar(msg)
        viewModel.clearSendToTvStatus()
    }

    androidx.compose.material3.Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        containerColor = MaterialTheme.colorScheme.background,
    ) { innerPadding ->
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .padding(innerPadding)
            .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        contentPadding = PaddingValues(vertical = 16.dp),
    ) {

        // ── Profiles ─────────────────────────────────────────────────────────
        item {
            var showAddDialog by remember { mutableStateOf(false) }

            SettingsSection("Подключения") {
                if (profiles.isEmpty()) {
                    Text(
                        "Нет профилей. Добавьте подключение.",
                        style = MaterialTheme.typography.bodySmall,
                        color = TextSecondary,
                    )
                } else {
                    profiles.forEachIndexed { index, profile ->
                        if (index > 0) HorizontalDivider(Modifier.padding(vertical = 4.dp))
                        ProfileRow(
                            profile = profile,
                            isActive = profile.id == activeProfileId,
                            onSelect = { viewModel.setActiveProfile(profile.id) },
                            onDelete = { viewModel.deleteProfile(profile.id) },
                            onAdminClick = if (profile.adminUrl != null) {
                                { onAdminNavigate(profile.id) }
                            } else null,
                            onShareToTv = if (!isAndroidTv) {
                                { onShareToTv(profile.id) }
                            } else null,
                            latencyMs = pingResults[profile.id],
                            isPinging = profile.id in pinging,
                            onPing = { viewModel.pingProfile(profile.id) },
                            subscriptionText = profileSubscriptions[profile.id],
                        )
                    }
                }

                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(
                        onClick = { showAddDialog = true },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Filled.Add, null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Добавить")
                    }
                    OutlinedButton(
                        onClick = { viewModel.pingAll() },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Filled.Refresh, null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Ping все")
                    }
                }

                if (importStatus.isNotEmpty()) {
                    Spacer(Modifier.height(4.dp))
                    Text(importStatus, style = MaterialTheme.typography.bodySmall)
                }
            }

            if (showAddDialog) {
                AddProfileDialog(
                    connString = pendingConnString,
                    name = pendingName,
                    onConnStringChange = { viewModel.setPendingConnString(it) },
                    onNameChange = { viewModel.setPendingName(it) },
                    onPasteFromClipboard = {
                        clipboardManager.getText()?.text?.let { viewModel.setPendingConnString(it) }
                    },
                    onQrScanner = onNavigateToQrScanner,
                    onConfirm = {
                        viewModel.importConfig()
                        showAddDialog = false
                    },
                    onDismiss = {
                        viewModel.setPendingConnString("")
                        viewModel.setPendingName("")
                        showAddDialog = false
                    },
                )
            }
        }

        // ── DNS ──────────────────────────────────────────────────────────────
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
                Spacer(Modifier.height(8.dp))
                Text(
                    "Для DNS-over-HTTPS/TLS включите «Личный DNS» в системных настройках Android (Настройки → Сеть → Расширенные → Личный DNS).",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                )
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

        // ── Network ──────────────────────────────────────────────────────────
        item {
            SettingsSection("Сеть") {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("Не проверять сертификат сервера")
                        Text(
                            "Нужно только при ручной настройке без CA. Строка подключения v0.7+ включает CA автоматически — этот переключатель не требуется.",
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

        // ── Routing ──────────────────────────────────────────────────────────
        item {
            val downloadStatus by viewModel.downloadStatus.collectAsStateWithLifecycle()
            val downloadedRules by viewModel.downloadedRules.collectAsStateWithLifecycle()
            val downloading by viewModel.downloading.collectAsStateWithLifecycle()

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
                        val ruleInfo = downloadedRules[code]
                        val isDownloading = code in downloading
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
                                when {
                                    isDownloading -> Text(
                                        "загрузка...",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.primary,
                                    )
                                    ruleInfo != null -> {
                                        val date = java.text.SimpleDateFormat(
                                            "dd.MM.yy",
                                            java.util.Locale.getDefault(),
                                        ).format(java.util.Date(ruleInfo.lastUpdated))
                                        Text(
                                            "${ruleInfo.cidrCount} подсетей · $date",
                                            style = MaterialTheme.typography.bodySmall,
                                            color = TextSecondary,
                                        )
                                    }
                                    else -> Text(
                                        "не загружен",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = TextSecondary,
                                    )
                                }
                            }
                            if (isDownloading) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(24.dp),
                                    strokeWidth = 2.dp,
                                )
                            } else {
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

        // ── Per-app ──────────────────────────────────────────────────────────
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

        // ── Theme ────────────────────────────────────────────────────────────
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

        // ── About ────────────────────────────────────────────────────────────
        item {
            SettingsSection("О приложении") {
                Text("GhostStream VPN", style = MaterialTheme.typography.titleMedium)
                Text(
                    "v${com.ghoststream.vpn.BuildConfig.VERSION_NAME}",
                    style = MaterialTheme.typography.bodySmall,
                    color = TextSecondary,
                )
            }
        }

        // ── TV Pairing (только на Android TV) ────────────────────────────────
        if (isAndroidTv) {
            item {
                OutlinedButton(
                    onClick = onGetFromPhone,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Filled.Tv, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Получить подключение с телефона")
                }
            }
        }

        // ── Debug share ───────────────────────────────────────────────────────
        item {
            OutlinedButton(
                onClick = { viewModel.shareDebugReport(context) },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Filled.BugReport, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Поделиться отладочной информацией")
            }
        }
    }
    } // Scaffold
}

// ── Profile row ──────────────────────────────────────────────────────────────

@Composable
private fun ProfileRow(
    profile: VpnProfile,
    isActive: Boolean,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
    onAdminClick: (() -> Unit)? = null,
    onShareToTv: (() -> Unit)? = null,
    latencyMs: Long? = null,
    isPinging: Boolean = false,
    onPing: () -> Unit = {},
    subscriptionText: String? = null,
) {
    var showDeleteConfirm by remember { mutableStateOf(false) }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onSelect() }
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = isActive, onClick = onSelect)
        Spacer(Modifier.width(4.dp))
        Column(Modifier.weight(1f)) {
            Text(profile.name, style = MaterialTheme.typography.bodyMedium)
            if (profile.serverAddr.isNotBlank()) {
                Text(
                    profile.serverAddr,
                    style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                    color = TextSecondary,
                )
            }
            if (subscriptionText != null) {
                Text(
                    "Подписка: $subscriptionText",
                    style = MaterialTheme.typography.bodySmall,
                    color = if (subscriptionText.contains("⚠")) RedError else TextSecondary,
                )
            }
        }
        // Latency badge
        if (isPinging) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(4.dp))
        } else {
            val latencyColor = when {
                latencyMs == null -> Color.Unspecified
                latencyMs < 100   -> GreenConnected
                latencyMs < 300   -> YellowWarning
                else              -> RedError
            }
            Surface(
                shape = RoundedCornerShape(8.dp),
                color = Color.Transparent,
                modifier = Modifier.clickable(onClick = onPing),
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Filled.NetworkCheck,
                        "Ping",
                        modifier = Modifier.size(14.dp),
                        tint = if (latencyMs != null) latencyColor else TextSecondary,
                    )
                    if (latencyMs != null) {
                        Spacer(Modifier.width(2.dp))
                        Text(
                            "${latencyMs}ms",
                            style = MaterialTheme.typography.labelSmall,
                            color = latencyColor,
                        )
                    }
                }
            }
        }
        if (onShareToTv != null) {
            IconButton(onClick = onShareToTv, modifier = Modifier.size(40.dp)) {
                Icon(Icons.Filled.Cast, "Отправить на TV", modifier = Modifier.size(18.dp))
            }
        }
        if (onAdminClick != null) {
            IconButton(onClick = onAdminClick, modifier = Modifier.size(40.dp)) {
                Icon(Icons.Filled.AdminPanelSettings, "Управление сервером", modifier = Modifier.size(18.dp))
            }
        }
        IconButton(onClick = { showDeleteConfirm = true }) {
            Icon(Icons.Filled.Delete, "Удалить", tint = MaterialTheme.colorScheme.error)
        }
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Удалить профиль?") },
            text = { Text("«${profile.name}» будет удалён безвозвратно.") },
            confirmButton = {
                TextButton(onClick = { onDelete(); showDeleteConfirm = false }) {
                    Text("Удалить", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text("Отмена") }
            },
        )
    }
}

// ── Add profile dialog ───────────────────────────────────────────────────────

@Composable
private fun AddProfileDialog(
    connString: String,
    name: String,
    onConnStringChange: (String) -> Unit,
    onNameChange: (String) -> Unit,
    onPasteFromClipboard: () -> Unit,
    onQrScanner: () -> Unit,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Добавить подключение") },
        text = {
            Column {
                OutlinedTextField(
                    value = name,
                    onValueChange = onNameChange,
                    label = { Text("Название (необязательно)") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = connString,
                    onValueChange = onConnStringChange,
                    label = { Text("Строка подключения") },
                    modifier = Modifier.fillMaxWidth(),
                    textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = 11.sp),
                    minLines = 3,
                    maxLines = 6,
                )
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = onPasteFromClipboard, modifier = Modifier.weight(1f)) {
                        Text("Из буфера", fontSize = 12.sp)
                    }
                    OutlinedButton(onClick = onQrScanner, modifier = Modifier.weight(1f)) {
                        Text("QR-код", fontSize = 12.sp)
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = onConfirm, enabled = connString.isNotBlank()) {
                Text("Добавить")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Отмена") }
        },
    )
}

// ── Shared composables ───────────────────────────────────────────────────────

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
