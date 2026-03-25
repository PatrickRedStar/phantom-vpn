package com.ghoststream.vpn.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.AccentTeal
import com.ghoststream.vpn.ui.theme.LocalGhostColors

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun DnsOverlay(viewModel: SettingsViewModel) {
    val gc = LocalGhostColors.current
    val config by viewModel.config.collectAsStateWithLifecycle()
    var newDns by remember { mutableStateOf("") }

    Column(
        modifier = Modifier
            .testTag("overlay_dns")
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Section: Mode info
        OvSection("Режим DNS") {
            Text(
                "Сейчас используется классический DNS по IP-адресам из списка ниже.",
                fontSize = 10.sp,
                color = gc.textTertiary,
                lineHeight = 14.5.sp,
            )
        }

        // Section: Active DNS servers
        OvSection("Активные серверы") {
            if (config.dnsServers.isEmpty()) {
                Text(
                    "DNS серверы не настроены. Добавьте вручную или выберите пресет.",
                    fontSize = 11.sp,
                    color = gc.textTertiary,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .border(0.5.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(12.dp))
                        .background(Color.White.copy(alpha = 0.05f))
                        .padding(14.dp),
                )
            } else {
                config.dnsServers.forEach { dns ->
                    OverlayDnsRow(
                        dns = dns,
                        onDelete = { viewModel.setDnsServers(config.dnsServers - dns) },
                        testTag = "dns_row_delete_${dns.replace(".", "_")}",
                    )
                }
            }
        }

        // Section: Add server
        OvSection("Добавить сервер") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BasicTextField(
                    value = newDns,
                    onValueChange = { newDns = it },
                    singleLine = true,
                    textStyle = TextStyle(
                        fontSize = 12.sp,
                        color = gc.textPrimary,
                        fontFamily = FontFamily.Monospace,
                    ),
                    cursorBrush = SolidColor(AccentTeal),
                    decorationBox = { inner ->
                        if (newDns.isEmpty()) {
                            Text("1.1.1.1", fontSize = 12.sp, color = gc.textTertiary.copy(alpha = 0.5f), fontFamily = FontFamily.Monospace)
                        }
                        inner()
                    },
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(12.dp))
                        .background(Color.White.copy(alpha = 0.05f))
                        .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                        .padding(12.dp),
                )
                Text(
                    "Добавить",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AccentPurple,
                    modifier = Modifier
                        .testTag("dns_add_server")
                        .clip(RoundedCornerShape(12.dp))
                        .background(AccentPurple.copy(alpha = 0.1f))
                        .border(0.5.dp, AccentPurple.copy(alpha = 0.28f), RoundedCornerShape(12.dp))
                        .clickable {
                            val trimmed = newDns.trim()
                            if (trimmed.isNotBlank() && trimmed !in config.dnsServers) {
                                viewModel.setDnsServers(config.dnsServers + trimmed)
                                newDns = ""
                            }
                        }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                )
            }
        }

        // Section: Quick presets
        OvSection("Быстрые пресеты") {
            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                DnsPreset("Google", listOf("8.8.8.8", "8.8.4.4"), config.dnsServers, viewModel, "dns_preset_google")
                DnsPreset("Cloudflare", listOf("1.1.1.1", "1.0.0.1"), config.dnsServers, viewModel, "dns_preset_cloudflare")
                DnsPreset("AdGuard", listOf("94.140.14.14", "94.140.15.15"), config.dnsServers, viewModel, "dns_preset_adguard")
                DnsPreset("Quad9", listOf("9.9.9.9"), config.dnsServers, viewModel, "dns_preset_quad9")
            }
        }
    }
}

@Composable
private fun OvSection(title: String, content: @Composable () -> Unit) {
    val gc = LocalGhostColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp))
            .padding(14.dp),
    ) {
        Text(
            title,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.9.sp,
            color = gc.textTertiary,
        )
        Spacer(Modifier.height(10.dp))
        content()
    }
}

@Composable
private fun OverlayDnsRow(dns: String, onDelete: () -> Unit, testTag: String) {
    val gc = LocalGhostColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(dns, fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = gc.textPrimary)
            Text("Primary", fontSize = 10.sp, color = gc.textTertiary)
        }
        androidx.compose.foundation.layout.Box(
            modifier = Modifier
                .testTag(testTag)
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
private fun DnsPreset(
    name: String,
    servers: List<String>,
    currentServers: List<String>,
    viewModel: SettingsViewModel,
    testTag: String,
) {
    val gc = LocalGhostColors.current
    val isActive = currentServers == servers
    val bg = if (isActive) AccentPurple.copy(alpha = 0.1f) else Color.White.copy(alpha = 0.05f)
    val border = if (isActive) AccentPurple.copy(alpha = 0.4f) else gc.cardBorder
    val textColor = if (isActive) gc.accent else gc.textSecondary

    Text(
        text = name,
        fontSize = 10.sp,
        fontWeight = FontWeight.Medium,
        color = textColor,
        modifier = Modifier
            .testTag(testTag)
            .clip(RoundedCornerShape(7.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(7.dp))
            .clickable { viewModel.setDnsServers(servers) }
            .padding(horizontal = 11.dp, vertical = 5.dp),
    )
}
