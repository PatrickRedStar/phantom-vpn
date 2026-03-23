package com.ghoststream.vpn.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.data.VpnProfile
import com.ghoststream.vpn.ui.components.BadgeVariant
import com.ghoststream.vpn.ui.components.GhostBadge
import com.ghoststream.vpn.ui.components.GhostCard
import com.ghoststream.vpn.ui.components.GhostToggle
import com.ghoststream.vpn.ui.components.PingBadge
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.AccentTeal
import com.ghoststream.vpn.ui.theme.DangerRose
import com.ghoststream.vpn.ui.theme.LocalGhostColors
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
    onOpenAddServer: () -> Unit = {},
    onOpenDns: () -> Unit = {},
    onOpenApps: () -> Unit = {},
    onOpenRoutes: () -> Unit = {},
) {
    val gc = LocalGhostColors.current
    val config by viewModel.config.collectAsStateWithLifecycle()
    val profiles by viewModel.profiles.collectAsStateWithLifecycle()
    val activeProfileId by viewModel.activeProfileId.collectAsStateWithLifecycle()
    val theme by viewModel.theme.collectAsStateWithLifecycle()
    val pingResults by viewModel.pingResults.collectAsStateWithLifecycle()
    val pinging by viewModel.pinging.collectAsStateWithLifecycle()
    val profileSubscriptions by viewModel.profileSubscriptions.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val isAndroidTv = remember {
        context.packageManager.hasSystemFeature("android.software.leanback")
    }

    Column(
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // ── Подключения ─────────────────────────────────────────────────────
        SectionLabel("Подключения")
        GhostCard {
            if (profiles.isEmpty()) {
                EmptyState("Подключений пока нет. Добавьте новый хост или отсканируйте QR-код.")
            } else {
                profiles.forEach { profile ->
                    ProfileRow(
                        profile = profile,
                        isActive = profile.id == activeProfileId,
                        onSelect = { viewModel.setActiveProfile(profile.id) },
                        onDelete = { viewModel.deleteProfile(profile.id) },
                        onAdminClick = if (profile.adminUrl != null) {
                            { onAdminNavigate(profile.id) }
                        } else null,
                        onQrClick = onNavigateToQrScanner,
                        latencyMs = pingResults[profile.id],
                        isPinging = profile.id in pinging,
                        onPing = { viewModel.pingProfile(profile.id) },
                        subscriptionText = profileSubscriptions[profile.id],
                    )
                }
            }

            // Action row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ActionButton(
                    text = "+ Добавить подключение",
                    isDashed = true,
                    modifier = Modifier.weight(1f),
                    onClick = onOpenAddServer,
                )
                ActionButton(
                    text = "↺ Ping все",
                    isPrimary = true,
                    modifier = Modifier.weight(1f),
                    onClick = { viewModel.pingAll() },
                )
            }
        }

        // ── DNS серверы ─────────────────────────────────────────────────────
        SectionLabel("DNS серверы")
        GhostCard(padding = 14.dp) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Кастомный DNS стек", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = gc.textPrimary)
                    Text(
                        "${config.dnsServers.size} сервера",
                        fontSize = 10.sp,
                        color = gc.textTertiary,
                    )
                }
                GhostBadge("DoH", BadgeVariant.ALT)
            }
            Spacer(Modifier.height(10.dp))
            // DNS list preview
            config.dnsServers.forEach { dns ->
                DnsRow(dns = dns, onDelete = {
                    viewModel.setDnsServers(config.dnsServers - dns)
                })
            }
            Spacer(Modifier.height(8.dp))
            // Presets
            FlowRow(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                listOf("Google", "Cloudflare", "AdGuard", "Quad9").forEach { name ->
                    PresetChip(text = name, isActive = false, onClick = {
                        val servers = when (name) {
                            "Google" -> listOf("8.8.8.8", "8.8.4.4")
                            "Cloudflare" -> listOf("1.1.1.1", "1.0.0.1")
                            "AdGuard" -> listOf("94.140.14.14", "94.140.15.15")
                            else -> listOf("9.9.9.9")
                        }
                        viewModel.setDnsServers(servers)
                    })
                }
            }
            Spacer(Modifier.height(8.dp))
            SubButton("Настроить DNS", onClick = onOpenDns)
        }

        // ── Сеть ────────────────────────────────────────────────────────────
        SectionLabel("Сеть")
        GhostCard {
            SettingsRow(
                title = "Не проверять сертификат",
                subtitle = "Только при ручной настройке без CA",
            ) {
                GhostToggle(
                    checked = config.insecure,
                    onCheckedChange = { viewModel.setInsecure(it) },
                )
            }
        }

        // ── Маршрутизация ───────────────────────────────────────────────────
        SectionLabel("Маршрутизация")
        GhostCard(padding = 14.dp) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Ручные правила проксирования", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = gc.textPrimary)
                    Text(
                        if (config.splitRouting) "${config.directCountries.size} правил" else "Выключено",
                        fontSize = 10.sp,
                        color = gc.textTertiary,
                    )
                }
                GhostBadge(
                    if (config.splitRouting) "SPLIT ON" else "OFF",
                    if (config.splitRouting) BadgeVariant.WARN else BadgeVariant.DEFAULT,
                )
            }
            Spacer(Modifier.height(10.dp))
            // Inline toggle
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(16.dp))
                    .background(Color.White.copy(alpha = 0.03f))
                    .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
                    .padding(12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Раздельная маршрутизация", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = gc.textPrimary)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Домены, IP и CIDR можно отправлять напрямую или через туннель.",
                        fontSize = 10.sp,
                        color = gc.textTertiary,
                        lineHeight = 14.5.sp,
                    )
                }
                Spacer(Modifier.width(12.dp))
                GhostToggle(
                    checked = config.splitRouting,
                    onCheckedChange = { viewModel.setSplitRouting(it) },
                )
            }
            Spacer(Modifier.height(8.dp))
            SubButton("Настроить маршруты", onClick = onOpenRoutes)
        }

        // ── Приложения ──────────────────────────────────────────────────────
        SectionLabel("Приложения")
        GhostCard(padding = 14.dp) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Маршрутизация приложений", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = gc.textPrimary)
                    Text(
                        when (config.perAppMode) {
                            "disallowed" -> "Все, кроме ${config.perAppList.size} приложений"
                            "allowed" -> "Только ${config.perAppList.size} приложений"
                            else -> "Все приложения идут через VPN"
                        },
                        fontSize = 10.sp,
                        color = gc.textTertiary,
                    )
                }
                GhostBadge(
                    when (config.perAppMode) {
                        "disallowed" -> "EXCLUDE"
                        "allowed" -> "INCLUDE"
                        else -> "FULL"
                    },
                )
            }
            Spacer(Modifier.height(10.dp))
            // Mode cards
            AppModeCard("Все через VPN", "Полный туннель для всех приложений.", config.perAppMode == "none") {
                viewModel.setPerAppMode("none")
            }
            Spacer(Modifier.height(8.dp))
            AppModeCard("Все, кроме выбранных", "Добавь приложения-исключения.", config.perAppMode == "disallowed") {
                viewModel.setPerAppMode("disallowed")
            }
            Spacer(Modifier.height(8.dp))
            AppModeCard("Только выбранные", "Через VPN только выбранные приложения.", config.perAppMode == "allowed") {
                viewModel.setPerAppMode("allowed")
            }
            Spacer(Modifier.height(8.dp))
            SubButton("Настроить приложения", onClick = onOpenApps)
            Spacer(Modifier.height(6.dp))
            Text(
                "Используй выбор приложений, если нужны банковские исключения или selective routing.",
                fontSize = 10.sp,
                color = gc.textTertiary,
                lineHeight = 14.5.sp,
            )
        }

        // ── Оформление ──────────────────────────────────────────────────────
        SectionLabel("Оформление")
        GhostCard(padding = 14.dp) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                ThemeOption("Тёмная", theme == "dark", Modifier.weight(1f)) { viewModel.setTheme("dark") }
                ThemeOption("Светлая", theme == "light", Modifier.weight(1f)) { viewModel.setTheme("light") }
                ThemeOption("Авто", theme == "system", Modifier.weight(1f)) { viewModel.setTheme("system") }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                "Текущий режим: ${when (theme) { "dark" -> "тёмная тема"; "light" -> "светлая тема"; else -> "системная тема" }}.",
                fontSize = 10.sp,
                color = gc.textTertiary,
                lineHeight = 14.sp,
            )
        }

        // ── TV Pairing ──────────────────────────────────────────────────────
        if (isAndroidTv) {
            SubButton("Получить подключение с телефона", onClick = onGetFromPhone)
        }

        // ── Поддержка ───────────────────────────────────────────────────────
        SectionLabel("Поддержка")
        DebugShareButton { viewModel.shareDebugReport(context) }

        // ── О приложении ────────────────────────────────────────────────────
        SectionLabel("О приложении")
        GhostCard {
            SettingsRow(
                icon = "👻",
                title = "GhostStream VPN",
                subtitle = "v${com.ghoststream.vpn.BuildConfig.VERSION_NAME} · QUIC / Noise Protocol",
            )
        }

        Spacer(Modifier.height(6.dp))
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Sub-composables
// ═══════════════════════════════════════════════════════════════════════════

@Composable
private fun SectionLabel(text: String) {
    val gc = LocalGhostColors.current
    Text(
        text = text,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 1.2.sp,
        color = gc.accent,
        modifier = Modifier.padding(start = 2.dp, top = 4.dp, bottom = 2.dp),
    )
}

@Composable
private fun SettingsRow(
    title: String,
    subtitle: String? = null,
    icon: String? = null,
    trailing: (@Composable () -> Unit)? = null,
) {
    val gc = LocalGhostColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (icon != null) {
            Text(icon, fontSize = 14.sp)
        }
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 12.sp, fontWeight = FontWeight.Medium, color = gc.textPrimary)
            if (subtitle != null) {
                Spacer(Modifier.height(1.dp))
                Text(subtitle, fontSize = 10.sp, color = gc.textTertiary)
            }
        }
        trailing?.invoke()
    }
}

@Composable
private fun ProfileRow(
    profile: VpnProfile,
    isActive: Boolean,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
    onAdminClick: (() -> Unit)?,
    onQrClick: () -> Unit,
    latencyMs: Long?,
    isPinging: Boolean,
    onPing: () -> Unit,
    subscriptionText: String?,
) {
    val gc = LocalGhostColors.current
    var showDeleteConfirm by remember { mutableStateOf(false) }

    // Main row
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onSelect),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 14.dp, end = 14.dp, top = 14.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            // Radio dot
            Box(
                modifier = Modifier
                    .size(16.dp)
                    .clip(CircleShape)
                    .border(2.dp, if (isActive) gc.accent else gc.cardBorder, CircleShape),
                contentAlignment = Alignment.Center,
            ) {
                if (isActive) {
                    Box(
                        Modifier
                            .size(6.dp)
                            .clip(CircleShape)
                            .background(gc.accent),
                    )
                }
            }

            Column(Modifier.weight(1f)) {
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        profile.name,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = gc.textPrimary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    PingBadge(latencyMs = latencyMs, isPinging = isPinging)
                }
                if (profile.serverAddr.isNotBlank()) {
                    Text(
                        profile.serverAddr,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 10.sp,
                        color = gc.textTertiary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }

        // Tools row
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 50.dp, end = 14.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            IconAction(Icons.Filled.QrCodeScanner, "QR") { onQrClick() }
            if (onAdminClick != null) {
                IconAction(Icons.Filled.Shield, "Admin", tintHover = AccentPurple) { onAdminClick() }
            }
            IconAction(Icons.Filled.Delete, "Удалить", tintHover = DangerRose) { showDeleteConfirm = true }
        }
    }

    if (showDeleteConfirm) {
        AlertDialog(
            onDismissRequest = { showDeleteConfirm = false },
            title = { Text("Удалить профиль?") },
            text = { Text("«${profile.name}» будет удалён безвозвратно.") },
            confirmButton = {
                TextButton(onClick = { onDelete(); showDeleteConfirm = false }) {
                    Text("Удалить", color = RedError)
                }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteConfirm = false }) { Text("Отмена") }
            },
        )
    }
}

@Composable
private fun IconAction(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    desc: String,
    tintHover: Color = LocalGhostColors.current.textSecondary,
    onClick: () -> Unit,
) {
    val gc = LocalGhostColors.current
    Box(
        modifier = Modifier
            .size(34.dp)
            .clip(RoundedCornerShape(11.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(11.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, desc, tint = gc.textSecondary, modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun DnsRow(dns: String, onDelete: () -> Unit) {
    val gc = LocalGhostColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.03f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(dns, fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = gc.textPrimary)
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .clickable(onClick = onDelete),
            contentAlignment = Alignment.Center,
        ) {
            Text("×", fontSize = 13.sp, color = gc.textTertiary)
        }
    }
}

@Composable
private fun PresetChip(text: String, isActive: Boolean, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    val bg = if (isActive) AccentPurple.copy(alpha = 0.1f) else Color.White.copy(alpha = 0.04f)
    val border = if (isActive) AccentPurple.copy(alpha = 0.4f) else gc.cardBorder
    val textColor = if (isActive) gc.accent else gc.textSecondary

    Text(
        text = text,
        fontSize = 10.sp,
        fontWeight = FontWeight.Medium,
        color = textColor,
        modifier = Modifier
            .clip(RoundedCornerShape(7.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(7.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 5.dp),
    )
}

@Composable
private fun ActionButton(
    text: String,
    modifier: Modifier = Modifier,
    isDashed: Boolean = false,
    isPrimary: Boolean = false,
    onClick: () -> Unit,
) {
    val gc = LocalGhostColors.current
    val bg = when {
        isDashed -> AccentPurple.copy(alpha = 0.08f)
        isPrimary -> AccentPurple.copy(alpha = 0.1f)
        else -> Color.White.copy(alpha = 0.04f)
    }
    val border = when {
        isDashed -> AccentPurple.copy(alpha = 0.3f)
        isPrimary -> AccentPurple.copy(alpha = 0.35f)
        else -> Color.White.copy(alpha = 0.1f)
    }
    val textColor = when {
        isDashed -> Color(0xFFD8D1FF)
        isPrimary -> gc.accent
        else -> gc.textSecondary
    }

    Text(
        text = text,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        color = textColor,
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 8.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

@Composable
private fun SubButton(text: String, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    Text(
        text = text,
        fontSize = 11.sp,
        color = gc.textSecondary,
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
    )
}

@Composable
private fun AppModeCard(title: String, desc: String, isActive: Boolean, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    val bg = if (isActive) AccentPurple.copy(alpha = 0.1f) else Color.White.copy(alpha = 0.03f)
    val border = if (isActive) AccentPurple.copy(alpha = 0.34f) else Color.White.copy(alpha = 0.08f)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
    ) {
        Text(title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = gc.textPrimary)
        Spacer(Modifier.height(4.dp))
        Text(desc, fontSize = 10.sp, color = gc.textTertiary, lineHeight = 14.5.sp)
    }
}

@Composable
private fun ThemeOption(label: String, isActive: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    val bg = if (isActive) AccentPurple.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.04f)
    val border = if (isActive) AccentPurple.copy(alpha = 0.38f) else gc.cardBorder

    Text(
        text = label,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        color = if (isActive) gc.accent else gc.textSecondary,
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 11.dp),
    )
}

@Composable
private fun DebugShareButton(onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(AccentTeal.copy(alpha = 0.09f))
            .border(0.5.dp, AccentTeal.copy(alpha = 0.22f), RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Text("🪲", fontSize = 16.sp)
        Spacer(Modifier.width(10.dp))
        Text(
            "Поделиться отладочной информацией",
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
            color = AccentTeal,
        )
    }
}

@Composable
private fun EmptyState(text: String) {
    val gc = LocalGhostColors.current
    Text(
        text = text,
        fontSize = 12.sp,
        color = gc.textTertiary,
        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
            .clip(RoundedCornerShape(14.dp))
            .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.02f))
            .padding(14.dp),
    )
}
