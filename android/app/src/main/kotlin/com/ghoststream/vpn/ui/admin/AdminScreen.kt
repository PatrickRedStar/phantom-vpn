package com.ghoststream.vpn.ui.admin

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.ProfilesStore
import com.ghoststream.vpn.data.VpnProfile
import com.ghoststream.vpn.ui.components.DashedHairline
import com.ghoststream.vpn.ui.components.GhostCard
import com.ghoststream.vpn.ui.components.GhostDialog
import com.ghoststream.vpn.ui.components.GhostDialogButton
import com.ghoststream.vpn.ui.components.GhostFab
import com.ghoststream.vpn.ui.components.GhostFullDialog
import com.ghoststream.vpn.ui.components.GhostTextFieldShape
import com.ghoststream.vpn.ui.components.HeaderMeta
import com.ghoststream.vpn.ui.components.PulseDot
import com.ghoststream.vpn.ui.components.ScreenHeader
import com.ghoststream.vpn.ui.components.ghostTextFieldColors
import com.ghoststream.vpn.ui.components.hairlineBottom
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText
import com.ghoststream.vpn.ui.theme.JetBrainsMono
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

@Composable
fun AdminScreen(
    profile: VpnProfile,
    onBack: () -> Unit,
    viewModel: AdminViewModel = viewModel(),
) {
    val ctx = LocalContext.current
    LaunchedEffect(profile.id) {
        viewModel.init(profile, ProfilesStore.getInstance(ctx))
    }

    val status by viewModel.status.collectAsStateWithLifecycle()
    val clients by viewModel.clients.collectAsStateWithLifecycle()
    val error by viewModel.error.collectAsStateWithLifecycle()
    val newConnString by viewModel.newConnString.collectAsStateWithLifecycle()

    var showAddDialog by remember { mutableStateOf(false) }
    var deleteConfirm by remember { mutableStateOf<String?>(null) }
    var toggleConfirm by remember { mutableStateOf<ClientInfo?>(null) }
    var showStatsDialog by remember { mutableStateOf<String?>(null) }
    var showSubDialog by remember { mutableStateOf<ClientInfo?>(null) }

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
        GhostDialog(
            onDismissRequest = { deleteConfirm = null },
            title = stringResource(R.string.admin_delete_title),
            content = {
                Text(stringResource(R.string.admin_delete_msg, name), color = C.textDim, style = GsText.kvValue)
            },
            confirmButton = {
                GhostDialogButton(stringResource(R.string.action_delete), onClick = { viewModel.deleteClient(name); deleteConfirm = null }, color = C.danger)
            },
            dismissButton = {
                GhostDialogButton(stringResource(R.string.action_cancel), onClick = { deleteConfirm = null }, color = C.textDim)
            },
        )
    }

    toggleConfirm?.let { client ->
        GhostDialog(
            onDismissRequest = { toggleConfirm = null },
            title = stringResource(if (client.enabled) R.string.admin_disable_title else R.string.admin_enable_title),
            content = {
                Text(
                    stringResource(if (client.enabled) R.string.admin_will_disable else R.string.admin_will_enable, client.name),
                    color = C.textDim,
                    style = GsText.kvValue,
                )
            },
            confirmButton = {
                GhostDialogButton(
                    stringResource(if (client.enabled) R.string.admin_action_disable else R.string.admin_action_enable),
                    onClick = {
                        viewModel.toggleEnabled(client.name, client.enabled)
                        toggleConfirm = null
                    },
                )
            },
            dismissButton = {
                GhostDialogButton(stringResource(R.string.action_cancel), onClick = { toggleConfirm = null }, color = C.textDim)
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

    Box(modifier = Modifier.fillMaxSize().background(C.bg)) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = 96.dp),
        ) {
            item {
                ScreenHeader(
                    brand = stringResource(R.string.brand_control),
                    meta = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            HeaderMeta(text = stringResource(R.string.admin_mtls_you))
                            Spacer(Modifier.width(6.dp))
                            PulseDot()
                            Spacer(Modifier.width(10.dp))
                            Text(
                                "✕",
                                style = GsText.hdrMeta,
                                color = C.textDim,
                                modifier = Modifier.clickable { onBack() },
                            )
                        }
                    },
                )
            }

            // Error banner
            if (error != null) {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 18.dp, vertical = 10.dp)
                            .background(C.danger.copy(alpha = 0.1f))
                            .padding(12.dp),
                    ) {
                        Text(error!!, color = C.danger, style = GsText.kvValue)
                        Spacer(Modifier.height(6.dp))
                        Text(
                            stringResource(R.string.admin_retry).uppercase(),
                            style = GsText.labelMono,
                            color = C.signal,
                            modifier = Modifier.clickable { viewModel.refresh() },
                        )
                    }
                }
            }

            // Stat grid
            item {
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 18.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    val s = status
                    StatCell(
                        label = stringResource(R.string.admin_uptime),
                        value = s?.let { formatUptimeShort(it.uptimeSecs) } ?: "—",
                        unit = "",
                        modifier = Modifier.weight(1f),
                    )
                    StatCell(
                        label = stringResource(R.string.admin_sessions),
                        value = s?.sessionsActive?.toString() ?: "—",
                        unit = "",
                        isSignal = (s?.sessionsActive ?: 0) > 0,
                        modifier = Modifier.weight(1f),
                    )
                    StatCell(
                        label = stringResource(R.string.admin_egress),
                        value = formatBytesBig(clients.sumOf { it.bytesRx + it.bytesTx }),
                        unit = "",
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            // Clients label
            item {
                Spacer(Modifier.height(20.dp))
                Text(
                    text = stringResource(R.string.admin_clients_count, clients.size).uppercase(),
                    style = GsText.labelMono,
                    color = C.textFaint,
                    modifier = Modifier.padding(horizontal = 22.dp, vertical = 10.dp),
                )
            }

            items(clients, key = { it.name }) { client ->
                Box(Modifier.padding(horizontal = 18.dp, vertical = 4.dp)) {
                    ClientCard(
                        client = client,
                        onTap = {
                            showStatsDialog = client.name
                            viewModel.loadClientStats(client.name)
                            viewModel.loadClientLogs(client.name)
                        },
                        onToggle = { toggleConfirm = client },
                        onDelete = { deleteConfirm = client.name },
                        onCopyConnString = { viewModel.getConnString(client.name) },
                        onSubscription = { showSubDialog = client },
                    )
                }
            }
        }

        // FAB — bottom
        Box(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(C.bg)
                .padding(horizontal = 18.dp, vertical = 14.dp),
        ) {
            GhostFab(
                text = stringResource(R.string.admin_new_client),
                onClick = { showAddDialog = true },
                outline = true,
            )
        }
    }
}

// ── Stat cell ────────────────────────────────────────────────────────────────

@Composable
private fun StatCell(
    label: String,
    value: String,
    unit: String,
    modifier: Modifier = Modifier,
    isSignal: Boolean = false,
) {
    Column(
        modifier = modifier
            .background(C.bgElev)
            .hairlineBottom(C.hair)
            .padding(10.dp),
    ) {
        Text(
            text = label.uppercase(),
            style = GsText.labelMonoSmall,
            color = C.textFaint,
        )
        Spacer(Modifier.height(4.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(
                text = value,
                style = GsText.statValue,
                color = if (isSignal) C.signal else C.bone,
            )
            if (unit.isNotEmpty()) {
                Spacer(Modifier.width(3.dp))
                Text(
                    text = unit.uppercase(),
                    style = GsText.labelMonoTiny,
                    color = C.textFaint,
                )
            }
        }
    }
}

// ── Client card ──────────────────────────────────────────────────────────────

@Composable
private fun ClientCard(
    client: ClientInfo,
    onTap: () -> Unit,
    onToggle: () -> Unit,
    onDelete: () -> Unit,
    onCopyConnString: () -> Unit,
    onSubscription: () -> Unit,
) {
    val nowSecs = System.currentTimeMillis() / 1000
    val daysLeft: Long? = client.expiresAt?.let { (it - nowSecs) / 86400 }

    val tag: String
    val tagColor: Color
    when {
        !client.enabled -> {
            tag = "○ ${stringResource(R.string.tag_off)}"
            tagColor = C.textFaint
        }
        client.connected -> {
            tag = "◉ ${stringResource(R.string.tag_live)}"
            tagColor = C.signal
        }
        daysLeft != null && daysLeft < 7 -> {
            tag = "⚠ ${stringResource(R.string.tag_exp_days_left, daysLeft.toInt())}"
            tagColor = C.warn
        }
        else -> {
            val hrs = client.lastSeenSecs / 3600
            tag = "◌ ${stringResource(R.string.tag_idle)} · ${hrs}h"
            tagColor = C.textDim
        }
    }

    GhostCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onTap() },
        active = client.connected,
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = client.name,
                    style = GsText.clientName,
                    color = C.bone,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = tag.uppercase(),
                    style = GsText.labelMono,
                    color = tagColor,
                )
            }
            Spacer(Modifier.height(2.dp))
            Text(
                text = client.tunAddr.ifEmpty { "—" },
                style = GsText.host,
                color = C.textDim,
            )
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "↓ ${formatBytesBig(client.bytesRx)}",
                    style = GsText.valueMono,
                    color = C.bone,
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    text = "↑ ${formatBytesBig(client.bytesTx)}",
                    style = GsText.valueMono,
                    color = C.bone,
                )
                if (daysLeft != null) {
                    Spacer(Modifier.width(10.dp))
                    Text(
                        text = "· ${daysLeft}d".uppercase(),
                        style = GsText.labelMono,
                        color = C.textDim,
                    )
                }
                Spacer(Modifier.weight(1f))
                // tiny actions row
                Text(
                    text = "⋯",
                    color = C.textDim,
                    style = GsText.valueMono,
                    modifier = Modifier
                        .padding(horizontal = 4.dp)
                        .clickable { onSubscription() },
                )
                Text(
                    text = "QR",
                    color = C.textDim,
                    style = GsText.labelMono,
                    modifier = Modifier
                        .padding(horizontal = 6.dp)
                        .clickable { onCopyConnString() },
                )
                Text(
                    text = if (client.enabled) "ON" else "OFF",
                    color = if (client.enabled) C.signal else C.textFaint,
                    style = GsText.labelMono,
                    modifier = Modifier
                        .padding(horizontal = 6.dp)
                        .clickable { onToggle() },
                )
                Text(
                    text = "✕",
                    color = C.danger,
                    style = GsText.labelMono,
                    modifier = Modifier
                        .padding(start = 6.dp)
                        .clickable { onDelete() },
                )
            }
        }
    }
}

// ── Dialogs (restyled, same flow) ────────────────────────────────────────────

@Composable
private fun AddClientDialog(onConfirm: (String, Int?) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf("") }
    var daysText by remember { mutableStateOf("30") }
    GhostDialog(
        onDismissRequest = onDismiss,
        title = stringResource(R.string.admin_add_title),
        content = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = name,
                    onValueChange = { name = it },
                    label = { Text(stringResource(R.string.admin_add_name_hint)) },
                    singleLine = true,
                    colors = ghostTextFieldColors(),
                    shape = GhostTextFieldShape,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = daysText,
                    onValueChange = { daysText = it.filter { c -> c.isDigit() }.take(4) },
                    label = { Text(stringResource(R.string.admin_add_days_hint)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    colors = ghostTextFieldColors(),
                    shape = GhostTextFieldShape,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            GhostDialogButton(
                stringResource(R.string.admin_action_create),
                onClick = { onConfirm(name.trim(), daysText.toIntOrNull()) },
                enabled = name.isNotBlank(),
            )
        },
        dismissButton = {
            GhostDialogButton(stringResource(R.string.action_cancel), onClick = onDismiss, color = C.textDim)
        },
    )
}

@Composable
private fun ClientDetailsDialog(
    clientName: String,
    stats: List<StatsSample>,
    logs: List<DestEntry>,
    onDismiss: () -> Unit,
) {
    GhostFullDialog(
        onDismissRequest = onDismiss,
        title = clientName,
        content = {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                item {
                    Text(stringResource(R.string.admin_traffic_title).uppercase(), style = GsText.labelMono, color = C.textFaint)
                    Spacer(Modifier.height(4.dp))
                }
                if (stats.isEmpty()) {
                    item { Text(stringResource(R.string.admin_no_data), style = GsText.kvValue, color = C.textDim) }
                } else {
                    item {
                        val last = stats.last()
                        Text(
                            "↓ ${formatBytesBig(last.bytesRx)}  ↑ ${formatBytesBig(last.bytesTx)}",
                            style = GsText.kvValue,
                            color = C.bone,
                        )
                    }
                }
                item {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(R.string.admin_recent_dest, logs.size).uppercase(),
                        style = GsText.labelMono,
                        color = C.textFaint,
                    )
                }
                if (logs.isEmpty()) {
                    item { Text("—", style = GsText.kvValue, color = C.textDim) }
                } else {
                    items(logs.take(50)) { entry ->
                        Text(
                            "${entry.proto.uppercase()}  ${entry.dst}:${entry.port}  ${formatBytesBig(entry.bytes)}",
                            style = GsText.logMsg,
                            color = C.textDim,
                        )
                    }
                }
            }
        },
        confirmButton = {
            GhostDialogButton(stringResource(R.string.action_close), onClick = onDismiss, color = C.textDim)
        },
    )
}

@Composable
private fun SubscriptionDialog(
    client: ClientInfo,
    onManage: (action: String, days: Int?) -> Unit,
    onDismiss: () -> Unit,
) {
    val nowSecs = System.currentTimeMillis() / 1000
    val daysRemaining = client.expiresAt?.let { (it - nowSecs) / 86400 }

    var customDays by remember { mutableStateOf("") }

    GhostDialog(
        onDismissRequest = onDismiss,
        title = stringResource(R.string.admin_sub_title, client.name),
        content = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val statusText = when {
                    daysRemaining == null -> stringResource(R.string.admin_sub_perpetual)
                    daysRemaining < 0    -> stringResource(R.string.admin_sub_expired)
                    daysRemaining == 0L  -> stringResource(R.string.admin_sub_today)
                    else                 -> stringResource(R.string.admin_sub_active, daysRemaining.toInt())
                }
                val statusColor = when {
                    daysRemaining == null -> C.signal
                    daysRemaining < 0    -> C.danger
                    daysRemaining < 7    -> C.warn
                    else                 -> C.signal
                }
                Text(
                    statusText.uppercase(),
                    style = GsText.labelMono,
                    color = statusColor,
                )
                DashedHairline()
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(30, 90, 365).forEach { days ->
                        GhostDialogButton("+${days}d", onClick = { onManage("extend", days) })
                    }
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        value = customDays,
                        onValueChange = { customDays = it.filter { c -> c.isDigit() }.take(4) },
                        label = { Text(stringResource(R.string.admin_sub_days_hint)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                        colors = ghostTextFieldColors(),
                        shape = GhostTextFieldShape,
                        modifier = Modifier.weight(1f),
                    )
                    GhostDialogButton(
                        stringResource(R.string.admin_sub_set),
                        onClick = { customDays.toIntOrNull()?.let { onManage("set", it) } },
                        enabled = customDays.toIntOrNull() != null,
                    )
                }
                DashedHairline()
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    GhostDialogButton(stringResource(R.string.admin_sub_perpetual), onClick = { onManage("cancel", null) }, color = C.textDim)
                    GhostDialogButton(stringResource(R.string.admin_sub_revoke), onClick = { onManage("revoke", null) }, color = C.danger)
                }
            }
        },
        confirmButton = {
            GhostDialogButton(stringResource(R.string.action_close), onClick = onDismiss, color = C.textDim)
        },
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
    GhostDialog(
        onDismissRequest = onDismiss,
        title = stringResource(R.string.admin_conn_title),
        content = {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                qrBitmap?.let { bm ->
                    Image(bitmap = bm, contentDescription = null, modifier = Modifier.size(200.dp))
                }
                Text(
                    connString.take(120) + if (connString.length > 120) "…" else "",
                    color = C.textDim,
                    style = TextStyle(fontFamily = JetBrainsMono, fontSize = 10.sp),
                )
            }
        },
        confirmButton = {
            GhostDialogButton(
                stringResource(R.string.admin_action_copy),
                onClick = {
                    val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("conn_string", connString))
                    onDismiss()
                },
            )
        },
        dismissButton = {
            GhostDialogButton(stringResource(R.string.action_close), onClick = onDismiss, color = C.textDim)
        },
    )
}

// ── Helpers ──────────────────────────────────────────────────────────────────

private fun formatUptimeShort(secs: Long): String {
    val d = secs / 86400
    val h = (secs % 86400) / 3600
    return when {
        d > 0 -> "${d}d"
        h > 0 -> "${h}h"
        else  -> "${secs / 60}m"
    }
}

private fun formatBytesBig(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024L * 1024 -> "${"%.1f".format(bytes / 1024.0)} KB"
    bytes < 1024L * 1024 * 1024 -> "${"%.1f".format(bytes / (1024.0 * 1024))} MB"
    bytes < 1024L * 1024 * 1024 * 1024 -> "${"%.2f".format(bytes / (1024.0 * 1024 * 1024))} GB"
    else -> "${"%.2f".format(bytes / (1024.0 * 1024 * 1024 * 1024))} TB"
}
