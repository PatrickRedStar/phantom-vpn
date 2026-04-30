package com.ghoststream.vpn.ui.settings

import androidx.appcompat.app.AppCompatDelegate
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import com.ghoststream.vpn.ui.components.GhostDialog
import com.ghoststream.vpn.ui.components.GhostFullDialog
import com.ghoststream.vpn.ui.components.GhostDialogButton
import com.ghoststream.vpn.ui.components.ghostTextFieldColors
import com.ghoststream.vpn.ui.components.GhostTextFieldShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.os.LocaleListCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.R
import com.ghoststream.vpn.data.VpnProfile
import com.ghoststream.vpn.ui.components.DashedGhostCard
import com.ghoststream.vpn.ui.components.DashedHairline
import com.ghoststream.vpn.ui.components.GhostCard
import com.ghoststream.vpn.ui.components.GhostFab
import com.ghoststream.vpn.ui.components.GhostToggle
import com.ghoststream.vpn.ui.components.HeaderMeta
import com.ghoststream.vpn.ui.components.LangSwitch
import com.ghoststream.vpn.ui.components.ThemeSwitch
import com.ghoststream.vpn.ui.components.ScreenHeader
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.windowInsetsPadding
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsDanger
import com.ghoststream.vpn.ui.theme.GsSignal
import com.ghoststream.vpn.ui.theme.GsText
import com.ghoststream.vpn.ui.theme.GsTextFaint
import com.ghoststream.vpn.ui.theme.GsWarn

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
    val pingResults by viewModel.pingResults.collectAsStateWithLifecycle()
    val pinging by viewModel.pinging.collectAsStateWithLifecycle()
    val profileSubscriptions by viewModel.profileSubscriptions.collectAsStateWithLifecycle()
    val autoStart by viewModel.autoStartOnBoot.collectAsStateWithLifecycle()
    val languageOverride by viewModel.languageOverride.collectAsStateWithLifecycle()
    val theme by viewModel.theme.collectAsStateWithLifecycle()
    val appIcon by viewModel.appIcon.collectAsStateWithLifecycle()

    val clipboardManager = LocalClipboardManager.current
    val context = LocalContext.current
    var showAddDialog by remember { mutableStateOf(false) }
    var editingProfile by remember { mutableStateOf<VpnProfile?>(null) }
    var editName by remember { mutableStateOf("") }
    var showDnsPicker by remember { mutableStateOf(false) }
    var showPerAppPicker by remember { mutableStateOf(false) }
    var showSplitTunnel by remember { mutableStateOf(false) }

    val version = com.ghoststream.vpn.BuildConfig.VERSION_NAME
    val gitTag = com.ghoststream.vpn.BuildConfig.GIT_TAG

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(C.bg)
            .verticalScroll(rememberScrollState()),
    ) {
        ScreenHeader(
            brand = stringResource(R.string.brand_settings),
            meta = { HeaderMeta(text = stringResource(R.string.version_fmt, version, gitTag)) },
        )

        // ── Endpoints ────────────────────────────────────────────────────────
        SectionLabel(
            text = "${stringResource(R.string.set_endpoints)} · ${"%02d".format(profiles.size)}",
        )

        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            profiles.forEach { profile ->
                ProfileCard(
                    profile = profile,
                    active = profile.id == activeProfileId,
                    latencyMs = pingResults[profile.id],
                    isPinging = profile.id in pinging,
                    subscriptionText = profileSubscriptions[profile.id],
                    onTap = { viewModel.setActiveProfile(profile.id) },
                    onEdit = {
                        editingProfile = profile
                        editName = profile.name
                    },
                    onLongPressAdmin = if (profile.cachedIsAdmin == true) {
                        { onAdminNavigate(profile.id) }
                    } else null,
                )
            }

            DashedGhostCard(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { showAddDialog = true },
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 18.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = stringResource(R.string.profile_add_cta).uppercase(),
                        style = GsText.labelMono,
                        color = C.textDim,
                    )
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        // ── Routing ──────────────────────────────────────────────────────────
        SectionLabel(text = stringResource(R.string.set_routing))
        SectionCard {
            SettingRow(
                label = stringResource(R.string.row_dns),
                sub = config.dnsServers.joinToString(" · ").ifEmpty { "—" },
                right = {
                    Text(
                        stringResource(R.string.value_custom).uppercase(),
                        style = GsText.labelMono,
                        color = C.textDim,
                    )
                },
                onClick = { showDnsPicker = true },
                showDivider = true,
            )
            SettingRow(
                label = stringResource(R.string.row_split_tunnel),
                sub = if (config.splitRouting)
                    stringResource(R.string.sub_split_bypass, config.directCountries.size)
                else "Off",
                right = {
                    GhostToggle(
                        checked = config.splitRouting,
                        onToggle = { viewModel.setSplitRouting(!config.splitRouting) },
                    )
                },
                onClick = { showSplitTunnel = true },
                showDivider = true,
            )
            SettingRow(
                label = stringResource(R.string.row_per_app),
                sub = when (config.perAppMode) {
                    "disallowed" -> stringResource(R.string.sub_per_app_excluded, config.perAppList.size)
                    "allowed"    -> "${config.perAppList.size} apps selected"
                    else         -> "All through VPN"
                },
                right = {
                    GhostToggle(
                        checked = config.perAppMode != "none",
                        onToggle = {
                            viewModel.setPerAppMode(
                                if (config.perAppMode == "none") "disallowed" else "none",
                            )
                        },
                    )
                },
                onClick = {
                    if (config.perAppMode == "none") viewModel.setPerAppMode("disallowed")
                    viewModel.loadInstalledApps()
                    showPerAppPicker = true
                },
                showDivider = true,
            )
            SettingRow(
                label = stringResource(R.string.row_always_on),
                sub = stringResource(R.string.sub_always_on),
                right = {
                    GhostToggle(checked = autoStart, onToggle = { viewModel.setAutoStartOnBoot(!autoStart) })
                },
                showDivider = false,
            )
        }

        Spacer(Modifier.height(24.dp))

        // ── Appearance ───────────────────────────────────────────────────────
        SectionLabel(text = stringResource(R.string.set_appearance))
        SectionCard {
            SettingRow(
                label = stringResource(R.string.row_language),
                sub = stringResource(R.string.sub_interface_locale),
                right = {
                    LangSwitch(
                        selected = languageOverride,
                        onSelect = { code ->
                            viewModel.setLanguageOverride(code)
                            val locales = if (code.isNullOrBlank())
                                LocaleListCompat.getEmptyLocaleList()
                            else
                                LocaleListCompat.forLanguageTags(code)
                            AppCompatDelegate.setApplicationLocales(locales)
                        },
                    )
                },
                showDivider = true,
            )
            SettingRow(
                label = stringResource(R.string.row_theme),
                sub = stringResource(R.string.sub_theme_descr),
                right = {
                    ThemeSwitch(
                        selected = theme,
                        onSelect = { viewModel.setTheme(it) },
                    )
                },
                showDivider = true,
            )
            SettingRow(
                label = stringResource(R.string.row_app_icon),
                sub = stringResource(R.string.sub_app_icon),
                right = {
                    IconSwitch(
                        selected = appIcon,
                        onSelect = { viewModel.setAppIcon(it) },
                    )
                },
                showDivider = false,
            )
        }

        Spacer(Modifier.height(24.dp))

        // ── Diagnostic ───────────────────────────────────────────────────────
        SectionLabel(text = stringResource(R.string.set_diagnostic))
        SectionCard {
            SettingRow(
                label = stringResource(R.string.row_share_debug),
                sub = stringResource(R.string.sub_debug_descr),
                right = {
                    Text(
                        stringResource(R.string.value_export).uppercase(),
                        style = GsText.labelMono,
                        color = C.signal,
                    )
                },
                onClick = { viewModel.shareDebugReport(context) },
                showDivider = false,
            )
        }

        Spacer(Modifier.height(100.dp))
    }

    // ── Split-Tunnel Dialog ─────────────────────────────────────────────
    if (showSplitTunnel) {
        val downloadedRules by viewModel.downloadedRules.collectAsStateWithLifecycle()
        val downloading by viewModel.downloading.collectAsStateWithLifecycle()
        val downloadStatus by viewModel.downloadStatus.collectAsStateWithLifecycle()
        val availableCountries = listOf(
            "ru" to "Russia", "ua" to "Ukraine", "by" to "Belarus",
            "kz" to "Kazakhstan", "cn" to "China", "ir" to "Iran",
        )
        GhostDialog(
            onDismissRequest = { showSplitTunnel = false },
            title = stringResource(R.string.split_title),
            content = {
                // Mode toggle
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    val splitOn = config.splitRouting
                    Text(
                        stringResource(R.string.split_mode_all).uppercase(),
                        style = GsText.labelMono,
                        color = if (!splitOn) C.signal else C.textFaint,
                        modifier = Modifier.clickable { viewModel.setSplitRouting(false) }.padding(4.dp),
                    )
                    Text(
                        stringResource(R.string.split_mode_bypass).uppercase(),
                        style = GsText.labelMono,
                        color = if (splitOn) C.signal else C.textFaint,
                        modifier = Modifier.clickable { viewModel.setSplitRouting(true) }.padding(4.dp),
                    )
                }
                Spacer(Modifier.height(12.dp))
                // Country list
                availableCountries.forEach { (code, name) ->
                    val selected = code in config.directCountries
                    val info = downloadedRules[code]
                    val isDownloading = code in downloading
                    Row(
                        Modifier.fillMaxWidth().padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        GhostToggle(
                            checked = selected,
                            onToggle = { viewModel.toggleDirectCountry(code) },
                        )
                        Spacer(Modifier.width(10.dp))
                        Column(Modifier.weight(1f)) {
                            Text(name, style = GsText.kvValue, color = C.bone)
                            if (info != null) {
                                Text(
                                    "${info.cidrCount} CIDRs · ${info.sizeKb} KB",
                                    style = GsText.host,
                                    color = C.textDim,
                                )
                            }
                        }
                        if (isDownloading) {
                            Text("…", style = GsText.labelMono, color = C.textDim)
                        } else {
                            Text(
                                (if (info != null) stringResource(R.string.split_downloaded) else stringResource(R.string.split_download)).uppercase(),
                                style = GsText.labelMono,
                                color = if (info != null) C.signal else C.textFaint,
                                modifier = Modifier.clickable { viewModel.downloadCountryRules(code) }.padding(4.dp),
                            )
                        }
                    }
                    DashedHairline()
                }
                if (downloadStatus.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(downloadStatus, style = GsText.host, color = C.textDim)
                }
            },
            confirmButton = {
                GhostDialogButton(stringResource(R.string.split_download_all), onClick = { viewModel.downloadAllSelected() }, color = C.textDim)
                Spacer(Modifier.width(12.dp))
                GhostDialogButton(stringResource(R.string.action_save), onClick = { showSplitTunnel = false })
            },
            dismissButton = {
                GhostDialogButton(stringResource(R.string.action_cancel), onClick = { showSplitTunnel = false }, color = C.textDim)
            },
        )
    }

    // ── DNS Picker Dialog ────────────────────────────────────────────────
    if (showDnsPicker) {
        var customDns by remember { mutableStateOf(config.dnsServers.joinToString(", ")) }
        GhostDialog(
            onDismissRequest = { showDnsPicker = false },
            title = stringResource(R.string.row_dns),
            content = {
                val presets = listOf(
                    "Cloudflare" to listOf("1.1.1.1", "1.0.0.1"),
                    "Google" to listOf("8.8.8.8", "8.8.4.4"),
                    "Quad9" to listOf("9.9.9.9", "149.112.112.112"),
                    "AdGuard" to listOf("94.140.14.14", "94.140.15.15"),
                )
                presets.forEach { (name, servers) ->
                    val isActive = config.dnsServers == servers
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable {
                                viewModel.setDnsServers(servers)
                                customDns = servers.joinToString(", ")
                            }
                            .padding(vertical = 10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            name,
                            style = GsText.profileName,
                            color = if (isActive) C.signal else C.bone,
                            modifier = Modifier.weight(1f),
                        )
                        Text(
                            servers.joinToString(" · "),
                            style = GsText.host,
                            color = C.textDim,
                        )
                    }
                    DashedHairline()
                }
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = customDns,
                    onValueChange = { customDns = it },
                    label = { Text(stringResource(R.string.dns_custom_hint)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    textStyle = TextStyle(fontFamily = com.ghoststream.vpn.ui.theme.JetBrainsMono, fontSize = 11.sp),
                    colors = ghostTextFieldColors(),
                    shape = GhostTextFieldShape,
                )
            },
            confirmButton = {
                GhostDialogButton(stringResource(R.string.action_save), onClick = {
                    val servers = customDns.split(",", " ")
                        .map { it.trim() }
                        .filter { it.matches(Regex("\\d+\\.\\d+\\.\\d+\\.\\d+")) }
                    viewModel.setDnsServers(servers)
                    showDnsPicker = false
                })
            },
            dismissButton = {
                GhostDialogButton(stringResource(R.string.action_cancel), onClick = { showDnsPicker = false }, color = C.textDim)
            },
        )
    }

    // ── Per-App Picker Dialog ────────────────────────────────────────────
    if (showPerAppPicker) {
        val installedApps by viewModel.installedApps.collectAsStateWithLifecycle()
        var searchQuery by remember { mutableStateOf("") }
        GhostFullDialog(
            onDismissRequest = { showPerAppPicker = false },
            title = stringResource(R.string.row_per_app),
            content = {
                // Mode toggle
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    val excludeLabel = stringResource(R.string.perapp_mode_exclude)
                    val onlyLabel = stringResource(R.string.perapp_mode_only)
                    listOf("disallowed" to excludeLabel, "allowed" to onlyLabel).forEach { (mode, label) ->
                        val active = config.perAppMode == mode
                        Text(
                            text = label.uppercase(),
                            style = GsText.labelMono,
                            color = if (active) C.signal else C.textFaint,
                            modifier = Modifier
                                .clickable { viewModel.setPerAppMode(mode) }
                                .padding(4.dp),
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))
                OutlinedTextField(
                    value = searchQuery,
                    onValueChange = { searchQuery = it },
                    label = { Text(stringResource(R.string.perapp_search_hint)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ghostTextFieldColors(),
                    shape = GhostTextFieldShape,
                )
                Spacer(Modifier.height(8.dp))
                val perAppSet = remember(config.perAppList) { config.perAppList.toSet() }
                val filtered = remember(installedApps, searchQuery, perAppSet) {
                    installedApps
                        .filter { !it.isSystem }
                        .filter { searchQuery.isBlank() || it.label.contains(searchQuery, true) || it.packageName.contains(searchQuery, true) }
                        .sortedByDescending { it.packageName in perAppSet }
                }
                val pm = context.packageManager
                androidx.compose.foundation.lazy.LazyColumn {
                    items(
                        count = filtered.size,
                        key = { filtered[it].packageName },
                    ) { idx ->
                        val app = filtered[idx]
                        val selected = app.packageName in perAppSet
                        Row(
                            Modifier
                                .fillMaxWidth()
                                .clickable { viewModel.togglePerApp(app.packageName) }
                                .padding(vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            // App icon (scaled to 32×32)
                            val iconBitmap = remember(app.packageName) {
                                runCatching {
                                    val d = pm.getApplicationIcon(app.packageName)
                                    val sz = 32
                                    val bmp = android.graphics.Bitmap.createBitmap(sz, sz, android.graphics.Bitmap.Config.ARGB_8888)
                                    val canvas = android.graphics.Canvas(bmp)
                                    d.setBounds(0, 0, sz, sz)
                                    d.draw(canvas)
                                    bmp.asImageBitmap()
                                }.getOrNull()
                            }
                            if (iconBitmap != null) {
                                androidx.compose.foundation.Image(
                                    bitmap = iconBitmap,
                                    contentDescription = app.label,
                                    modifier = Modifier.size(32.dp),
                                )
                                Spacer(Modifier.width(10.dp))
                            }
                            Column(Modifier.weight(1f)) {
                                Text(app.label, style = GsText.kvValue, color = C.bone)
                                Text(app.packageName, style = GsText.host, color = C.textFaint)
                            }
                            Spacer(Modifier.width(10.dp))
                            GhostToggle(
                                checked = selected,
                                onToggle = { viewModel.togglePerApp(app.packageName) },
                            )
                        }
                    }
                }
            },
            confirmButton = {
                GhostDialogButton(stringResource(R.string.action_save), onClick = { showPerAppPicker = false })
            },
            dismissButton = {
                GhostDialogButton(stringResource(R.string.action_cancel), onClick = { showPerAppPicker = false }, color = C.textDim)
            },
        )
    }

    // ── Edit Profile Dialog ────────────────────────────────────────────────
    if (editingProfile != null) {
        var showDeleteConfirm by remember { mutableStateOf(false) }
        var relayEnabled by remember(editingProfile) { mutableStateOf(editingProfile!!.relayEnabled) }
        var relayAddr by remember(editingProfile) { mutableStateOf(editingProfile!!.relayAddr ?: "") }
        GhostDialog(
            onDismissRequest = { editingProfile = null },
            title = stringResource(R.string.edit_profile_title),
            content = {
                OutlinedTextField(
                    value = editName,
                    onValueChange = { editName = it },
                    label = { Text(stringResource(R.string.edit_profile_name_hint)) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ghostTextFieldColors(),
                    shape = GhostTextFieldShape,
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    text = editingProfile!!.serverAddr,
                    style = GsText.host,
                    color = C.textDim,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "SNI: ${editingProfile!!.serverName}",
                    style = GsText.host,
                    color = C.textFaint,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "TUN: ${editingProfile!!.tunAddr}",
                    style = GsText.host,
                    color = C.textFaint,
                )
                // ── Relay ────────────────────────────────────────────
                Spacer(Modifier.height(12.dp))
                DashedHairline()
                Spacer(Modifier.height(12.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            stringResource(R.string.edit_relay_label),
                            style = GsText.profileName,
                            color = C.bone,
                        )
                        Spacer(Modifier.height(2.dp))
                        Text(
                            stringResource(R.string.edit_relay_sub),
                            style = GsText.host,
                            color = C.textDim,
                        )
                    }
                    Spacer(Modifier.width(12.dp))
                    GhostToggle(
                        checked = relayEnabled,
                        onToggle = { relayEnabled = !relayEnabled },
                    )
                }
                if (relayEnabled) {
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = relayAddr,
                        onValueChange = { relayAddr = it },
                        label = { Text(stringResource(R.string.edit_relay_hint)) },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        textStyle = TextStyle(fontFamily = com.ghoststream.vpn.ui.theme.JetBrainsMono, fontSize = 11.sp),
                        colors = ghostTextFieldColors(),
                        shape = GhostTextFieldShape,
                    )
                }
                if (editingProfile!!.cachedIsAdmin == true) {
                    Spacer(Modifier.height(12.dp))
                    GhostFab(
                        text = stringResource(R.string.action_admin_panel),
                        outline = true,
                        onClick = {
                            val id = editingProfile!!.id
                            editingProfile = null
                            onAdminNavigate(id)
                        },
                    )
                }
                Spacer(Modifier.height(12.dp))
                if (showDeleteConfirm) {
                    Text(
                        stringResource(R.string.confirm_delete),
                        style = GsText.body,
                        color = C.danger,
                    )
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        GhostDialogButton(stringResource(R.string.action_delete), onClick = {
                            viewModel.deleteProfile(editingProfile!!.id)
                            editingProfile = null
                        }, color = C.danger)
                        GhostDialogButton(stringResource(R.string.action_cancel), onClick = { showDeleteConfirm = false }, color = C.textDim)
                    }
                } else {
                    GhostDialogButton(stringResource(R.string.action_delete), onClick = { showDeleteConfirm = true }, color = C.danger)
                }
            },
            confirmButton = {
                GhostDialogButton(stringResource(R.string.action_save), onClick = {
                    viewModel.updateProfileFields(
                        editingProfile!!.id,
                        name = editName,
                        relayEnabled = relayEnabled,
                        relayAddr = relayAddr.trim().ifBlank { null },
                    )
                    editingProfile = null
                })
            },
            dismissButton = {
                GhostDialogButton(stringResource(R.string.action_cancel), onClick = { editingProfile = null }, color = C.textDim)
            },
        )
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
            onQrScanner = {
                showAddDialog = false
                onNavigateToQrScanner()
            },
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

// ── Section label ────────────────────────────────────────────────────────────

@Composable
private fun SectionLabel(text: String) {
    Text(
        text = text.uppercase(),
        style = GsText.labelMono,
        color = C.textFaint,
        modifier = Modifier.padding(horizontal = 22.dp, vertical = 12.dp),
    )
}

// ── Section card wrapper ─────────────────────────────────────────────────────

@Composable
private fun SectionCard(content: @Composable () -> Unit) {
    val hairColor = C.hair
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 18.dp)
            .background(C.bgElev)
            .drawBehind {
                // hairline border
                drawRect(
                    color = hairColor,
                    topLeft = Offset(0f, 0f),
                    size = androidx.compose.ui.geometry.Size(size.width, 1f),
                )
                drawRect(
                    color = hairColor,
                    topLeft = Offset(0f, size.height - 1f),
                    size = androidx.compose.ui.geometry.Size(size.width, 1f),
                )
                drawRect(
                    color = hairColor,
                    topLeft = Offset(0f, 0f),
                    size = androidx.compose.ui.geometry.Size(1f, size.height),
                )
                drawRect(
                    color = hairColor,
                    topLeft = Offset(size.width - 1f, 0f),
                    size = androidx.compose.ui.geometry.Size(1f, size.height),
                )
            },
    ) {
        content()
    }
}

// ── Setting row ──────────────────────────────────────────────────────────────

@Composable
private fun SettingRow(
    label: String,
    sub: String,
    right: @Composable () -> Unit,
    onClick: (() -> Unit)? = null,
    showDivider: Boolean = true,
) {
    Column(Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(label, style = GsText.profileName, color = C.bone)
                Spacer(Modifier.height(2.dp))
                Text(
                    sub,
                    style = GsText.host,
                    color = C.textDim,
                )
            }
            Spacer(Modifier.width(12.dp))
            right()
        }
        if (showDivider) {
            DashedHairline(modifier = Modifier.padding(horizontal = 14.dp))
        }
    }
}

// ── Profile card ─────────────────────────────────────────────────────────────

@Composable
private fun ProfileCard(
    profile: VpnProfile,
    active: Boolean,
    latencyMs: Long?,
    isPinging: Boolean,
    subscriptionText: String?,
    onTap: () -> Unit,
    onEdit: () -> Unit = {},
    onLongPressAdmin: (() -> Unit)? = null,
) {
    GhostCard(
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onTap() },
        active = active,
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = profile.name,
                    style = GsText.profileName,
                    color = C.bone,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = stringResource(R.string.value_edit).uppercase(),
                    style = GsText.labelMono,
                    color = C.textDim,
                    modifier = Modifier
                        .clickable { onEdit() }
                        .padding(4.dp),
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    text = if (active)
                        stringResource(R.string.tag_active).uppercase()
                    else
                        stringResource(R.string.tag_standby).uppercase(),
                    style = GsText.labelMono,
                    color = if (active) C.signal else C.textFaint,
                )
            }
            Spacer(Modifier.height(4.dp))
            Text(
                text = profile.serverAddr.ifEmpty { "—" },
                style = GsText.host,
                color = C.textDim,
            )
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                PingDot(latencyMs = latencyMs, isPinging = isPinging)
                Spacer(Modifier.width(6.dp))
                Text(
                    text = when {
                        isPinging       -> "…"
                        latencyMs == null -> "offline"
                        else            -> "${latencyMs} ms"
                    },
                    style = GsText.valueMono,
                    color = pingColor(latencyMs),
                )
                if (!subscriptionText.isNullOrBlank()) {
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = "· ${subscriptionText}".uppercase(),
                        style = GsText.labelMono,
                        color = if (subscriptionText.contains("⚠")) C.danger else C.textDim,
                    )
                }
                if (onLongPressAdmin != null) {
                    Spacer(Modifier.width(12.dp))
                    Text(
                        text = "· ${stringResource(R.string.tag_admin).uppercase()}",
                        style = GsText.labelMono,
                        color = C.signal,
                        modifier = Modifier.clickable { onLongPressAdmin() },
                    )
                }
            }
        }
    }
}

@Composable
private fun PingDot(latencyMs: Long?, isPinging: Boolean) {
    val color = pingColor(latencyMs)
    Box(
        modifier = Modifier
            .size(5.dp)
            .drawBehind {
                drawCircle(color = color)
                if (latencyMs != null && latencyMs < 100) {
                    drawCircle(color = color.copy(alpha = 0.3f), radius = size.minDimension)
                }
            },
    )
}

private fun pingColor(latencyMs: Long?): Color = when {
    latencyMs == null  -> GsTextFaint
    latencyMs < 100    -> GsSignal
    latencyMs < 300    -> GsWarn
    else               -> GsDanger
}

// ── Icon switch ─────────────────────────────────────────────────────────────

@Composable
private fun IconSwitch(
    selected: String, // "bone" | "scope"
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier
            .border(1.dp, C.hairBold)
            .padding(4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        val entries = listOf(
            "bone" to R.mipmap.ic_launcher,
            "scope" to R.mipmap.ic_launcher_scope,
        )
        entries.forEachIndexed { idx, (value, iconRes) ->
            val active = selected == value
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .then(
                        if (active) Modifier.border(1.dp, C.signal) else Modifier,
                    )
                    .clickable { onSelect(value) }
                    .padding(2.dp),
                contentAlignment = Alignment.Center,
            ) {
                Image(
                    painter = painterResource(iconRes),
                    contentDescription = value,
                    modifier = Modifier.size(28.dp),
                )
            }
        }
    }
}

// ── Add profile dialog ──────────────────────────────────────────────────────

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
    GhostDialog(
        onDismissRequest = onDismiss,
        title = stringResource(R.string.add_profile_title),
        content = {
            OutlinedTextField(
                value = name,
                onValueChange = onNameChange,
                label = { Text(stringResource(R.string.add_profile_name_hint)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
                colors = ghostTextFieldColors(),
                shape = GhostTextFieldShape,
            )
            Spacer(Modifier.height(8.dp))
            OutlinedTextField(
                value = connString,
                onValueChange = onConnStringChange,
                label = { Text(stringResource(R.string.add_profile_conn_hint)) },
                textStyle = TextStyle(fontFamily = com.ghoststream.vpn.ui.theme.JetBrainsMono, fontSize = 11.sp),
                minLines = 3,
                maxLines = 6,
                modifier = Modifier.fillMaxWidth(),
                colors = ghostTextFieldColors(),
                shape = GhostTextFieldShape,
            )
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                GhostDialogButton(stringResource(R.string.action_paste), onClick = onPasteFromClipboard, color = C.textDim)
                GhostDialogButton(stringResource(R.string.action_qr), onClick = onQrScanner, color = C.textDim)
            }
        },
        confirmButton = {
            GhostDialogButton(stringResource(R.string.action_add), onClick = onConfirm, enabled = connString.isNotBlank())
        },
        dismissButton = {
            GhostDialogButton(stringResource(R.string.action_cancel), onClick = onDismiss, color = C.textDim)
        },
    )
}

