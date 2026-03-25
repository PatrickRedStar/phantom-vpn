package com.ghoststream.vpn.ui.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.ui.components.GhostToggle
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.LocalGhostColors

@Composable
fun AppsOverlay(viewModel: SettingsViewModel) {
    val gc = LocalGhostColors.current
    val config by viewModel.config.collectAsStateWithLifecycle()
    val installedApps by viewModel.installedApps.collectAsStateWithLifecycle()

    LaunchedEffect(Unit) { viewModel.loadInstalledApps() }

    Column(
        modifier = Modifier
            .testTag("overlay_apps")
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        // Routing mode selection
        AppsSection("Режим маршрутизации") {
            AppModeCard(
                title = "Все через VPN",
                desc = "Полный туннель для всех приложений на устройстве.",
                isActive = config.perAppMode == "none",
                modifier = Modifier.testTag("apps_mode_none"),
            ) { viewModel.setPerAppMode("none") }

            Spacer(Modifier.height(8.dp))

            AppModeCard(
                title = "Все, кроме выбранных",
                desc = "Добавь приложения-исключения, которые пойдут мимо туннеля.",
                isActive = config.perAppMode == "disallowed",
                modifier = Modifier.testTag("apps_mode_disallowed"),
            ) { viewModel.setPerAppMode("disallowed") }

            Spacer(Modifier.height(8.dp))

            AppModeCard(
                title = "Только выбранные",
                desc = "Через VPN идут только приложения, которые ты явно выбрал.",
                isActive = config.perAppMode == "allowed",
                modifier = Modifier.testTag("apps_mode_allowed"),
            ) { viewModel.setPerAppMode("allowed") }

            if (config.perAppMode == "allowed" && config.perAppList.isEmpty()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    "Выбери минимум одно приложение, иначе подключение не запустится.",
                    fontSize = 10.sp,
                    lineHeight = 14.sp,
                    color = gc.textTertiary,
                )
            }
        }

        // App picker list
        if (config.perAppMode != "none") {
            AppsSection("Приложения") {
                if (installedApps.isEmpty()) {
                    Text(
                        "Загрузка списка приложений...",
                        fontSize = 11.sp,
                        color = gc.textTertiary,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .border(0.5.dp, Color.White.copy(alpha = 0.1f), RoundedCornerShape(12.dp))
                            .background(Color.White.copy(alpha = 0.05f))
                            .padding(14.dp),
                    )
                } else {
                    val userApps = installedApps.filter { !it.isSystem }
                    userApps.forEach { app ->
                        val isEnabled = app.packageName in config.perAppList
                        AppPickRow(
                            label = app.label,
                            packageName = app.packageName,
                            isEnabled = isEnabled,
                            onToggle = { viewModel.togglePerApp(app.packageName) },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AppsSection(title: String, content: @Composable () -> Unit) {
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
private fun AppModeCard(
    title: String,
    desc: String,
    isActive: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val gc = LocalGhostColors.current
    val bg = if (isActive) AccentPurple.copy(alpha = 0.1f) else Color.White.copy(alpha = 0.05f)
    val border = if (isActive) AccentPurple.copy(alpha = 0.34f) else Color.White.copy(alpha = 0.08f)

    Column(
        modifier = modifier
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
private fun AppPickRow(
    label: String,
    packageName: String,
    isEnabled: Boolean,
    onToggle: () -> Unit,
) {
    val gc = LocalGhostColors.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        // App icon placeholder
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(AccentPurple.copy(alpha = 0.12f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                label.take(1).uppercase(),
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = AccentPurple,
            )
        }
        Column(Modifier.weight(1f)) {
            Text(
                label,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = gc.textPrimary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                packageName,
                fontSize = 10.sp,
                color = gc.textTertiary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        GhostToggle(checked = isEnabled, onCheckedChange = { onToggle() })
    }
}
