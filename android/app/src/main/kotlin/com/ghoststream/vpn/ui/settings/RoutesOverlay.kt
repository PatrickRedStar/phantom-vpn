package com.ghoststream.vpn.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.ui.components.GhostToggle
import com.ghoststream.vpn.ui.components.SegmentRow
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.AccentTeal
import com.ghoststream.vpn.ui.theme.LocalGhostColors
import com.ghoststream.vpn.ui.theme.YellowWarning

private val DirectGreen = Color(0xFF86efac)
private val VpnLavender = Color(0xFFd8d1ff)

@Composable
fun RoutesOverlay(viewModel: SettingsViewModel) {
    val gc = LocalGhostColors.current
    val config by viewModel.config.collectAsStateWithLifecycle()
    val downloadedRules by viewModel.downloadedRules.collectAsStateWithLifecycle()
    val downloading by viewModel.downloading.collectAsStateWithLifecycle()
    val downloadStatus by viewModel.downloadStatus.collectAsStateWithLifecycle()
    var newRoute by remember { mutableStateOf("") }
    var routeType by remember { mutableStateOf("Direct") }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        // Split toggle section
        RouteSection("Основные настройки") {
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
        }

        if (config.splitRouting) {
            // Active rules
            RouteSection("Активные правила") {
                val countries = config.directCountries
                if (countries.isEmpty()) {
                    Text(
                        "Нет активных правил маршрутизации. Добавьте страну или CIDR ниже.",
                        fontSize = 11.sp,
                        color = gc.textTertiary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .border(0.5.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.02f))
                            .padding(14.dp),
                    )
                } else {
                    countries.forEach { code ->
                        val ruleInfo = downloadedRules[code]
                        RouteRuleRow(
                            title = code.uppercase(),
                            subtitle = ruleInfo?.let { "${it.cidrCount} CIDRs · ${it.sizeKb} КБ" } ?: "не загружен",
                            isDirect = true,
                            isActive = true,
                            isDownloading = code in downloading,
                            onRemove = { viewModel.toggleDirectCountry(code) },
                            onDownload = { viewModel.downloadCountryRules(code) },
                        )
                    }
                }
            }

            // Add rule
            RouteSection("Добавить правило") {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicTextField(
                        value = newRoute,
                        onValueChange = { newRoute = it },
                        singleLine = true,
                        textStyle = TextStyle(
                            fontSize = 12.sp,
                            color = gc.textPrimary,
                            fontFamily = FontFamily.Monospace,
                        ),
                        cursorBrush = SolidColor(AccentPurple),
                        decorationBox = { inner ->
                            if (newRoute.isEmpty()) {
                                Text("ru, us, 10.0.0.0/8...", fontSize = 12.sp, color = gc.textTertiary.copy(alpha = 0.5f), fontFamily = FontFamily.Monospace)
                            }
                            inner()
                        },
                        modifier = Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.04f))
                            .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
                            .padding(12.dp),
                    )
                    Text(
                        "+",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Bold,
                        color = AccentPurple,
                        textAlign = TextAlign.Center,
                        modifier = Modifier
                            .clip(RoundedCornerShape(12.dp))
                            .background(AccentPurple.copy(alpha = 0.1f))
                            .border(0.5.dp, AccentPurple.copy(alpha = 0.28f), RoundedCornerShape(12.dp))
                            .clickable {
                                val trimmed = newRoute.trim().lowercase()
                                if (trimmed.isNotBlank() && trimmed !in config.directCountries) {
                                    viewModel.toggleDirectCountry(trimmed)
                                    newRoute = ""
                                }
                            }
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                    )
                }

                Spacer(Modifier.height(10.dp))

                SegmentRow(
                    options = listOf("Direct", "VPN"),
                    selected = routeType,
                    onSelect = { routeType = it },
                )
            }

            // Presets
            RouteSection("Страны") {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    listOf("ru", "ua", "by").forEach { code ->
                        val isActive = code in config.directCountries
                        CountryChip(
                            code = code.uppercase(),
                            isActive = isActive,
                            modifier = Modifier.weight(1f),
                        ) { viewModel.toggleDirectCountry(code) }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Text(
                    "Загрузить все списки",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AccentPurple,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(12.dp))
                        .background(AccentPurple.copy(alpha = 0.08f))
                        .border(0.5.dp, AccentPurple.copy(alpha = 0.24f), RoundedCornerShape(12.dp))
                        .clickable { viewModel.downloadAllSelected() }
                        .padding(vertical = 10.dp),
                )
                if (downloadStatus.isNotBlank()) {
                    Spacer(Modifier.height(4.dp))
                    Text(downloadStatus, fontSize = 10.sp, color = gc.textTertiary)
                }
            }
        }
    }
}

@Composable
private fun RouteSection(title: String, content: @Composable () -> Unit) {
    val gc = LocalGhostColors.current
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.03f))
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
private fun RouteRuleRow(
    title: String,
    subtitle: String,
    isDirect: Boolean,
    isActive: Boolean,
    isDownloading: Boolean,
    onRemove: () -> Unit,
    onDownload: () -> Unit,
) {
    val gc = LocalGhostColors.current
    val checkColor = if (isDirect) AccentTeal else AccentPurple
    val pillColor = if (isDirect) DirectGreen else VpnLavender
    val pillBorder = if (isDirect) AccentTeal.copy(alpha = 0.22f) else AccentPurple.copy(alpha = 0.24f)
    val pillBg = if (isDirect) AccentTeal.copy(alpha = 0.1f) else AccentPurple.copy(alpha = 0.1f)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.03f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(14.dp))
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // Check mark
        Box(
            modifier = Modifier
                .size(18.dp)
                .clip(RoundedCornerShape(5.dp))
                .border(1.5.dp, if (isActive) checkColor else Color.White.copy(alpha = 0.3f), RoundedCornerShape(5.dp))
                .background(if (isActive) checkColor.copy(alpha = 0.15f) else Color.Transparent),
            contentAlignment = Alignment.Center,
        ) {
            if (isActive) {
                Box(Modifier.size(8.dp).clip(RoundedCornerShape(2.dp)).background(checkColor))
            }
        }
        Column(Modifier.weight(1f)) {
            Text(title, fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = gc.textPrimary)
            Spacer(Modifier.height(4.dp))
            Text(subtitle, fontSize = 10.sp, color = gc.textTertiary)
        }
        // Pill
        Text(
            if (isDirect) "direct" else "vpn",
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.3.sp,
            color = pillColor,
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(pillBg)
                .border(0.5.dp, pillBorder, RoundedCornerShape(999.dp))
                .padding(horizontal = 9.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun CountryChip(code: String, isActive: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    val bg = if (isActive) AccentPurple.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.04f)
    val border = if (isActive) AccentPurple.copy(alpha = 0.38f) else gc.cardBorder

    Text(
        text = code,
        fontSize = 11.sp,
        fontWeight = FontWeight.SemiBold,
        color = if (isActive) gc.accent else gc.textSecondary,
        textAlign = TextAlign.Center,
        modifier = modifier
            .clip(RoundedCornerShape(10.dp))
            .background(bg)
            .border(0.5.dp, border, RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(vertical = 9.dp),
    )
}
