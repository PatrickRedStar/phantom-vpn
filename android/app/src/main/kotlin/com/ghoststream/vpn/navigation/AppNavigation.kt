package com.ghoststream.vpn.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Article
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.ghoststream.vpn.ui.admin.AdminScreen
import com.ghoststream.vpn.ui.components.GhostOverlay
import com.ghoststream.vpn.ui.components.QrScannerScreen
import com.ghoststream.vpn.ui.dashboard.DashboardScreen
import com.ghoststream.vpn.ui.logs.LogsScreen
import com.ghoststream.vpn.ui.logs.LogsViewModel
import com.ghoststream.vpn.ui.pairing.TvPairingScreen
import com.ghoststream.vpn.ui.settings.AddServerOverlay
import com.ghoststream.vpn.ui.settings.AppsOverlay
import com.ghoststream.vpn.ui.settings.DnsOverlay
import com.ghoststream.vpn.ui.settings.RoutesOverlay
import com.ghoststream.vpn.ui.settings.SettingsScreen
import com.ghoststream.vpn.ui.settings.SettingsViewModel
import com.ghoststream.vpn.ui.theme.BlueDebug
import com.ghoststream.vpn.ui.theme.LocalGhostColors
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.AdminSheetStart
import com.ghoststream.vpn.ui.theme.AdminSheetEnd
import com.ghoststream.vpn.ui.theme.LogsSheetStart
import com.ghoststream.vpn.ui.theme.LogsSheetEnd
import com.ghoststream.vpn.ui.theme.SettSheetStart
import com.ghoststream.vpn.ui.theme.SettSheetEnd

// Which overlay is currently shown
sealed class Overlay {
    object None : Overlay()
    object Logs : Overlay()
    object Settings : Overlay()
    data class Admin(val adminUrl: String, val adminToken: String) : Overlay()
    object AddServer : Overlay()
    object Dns : Overlay()
    object Apps : Overlay()
    object Routes : Overlay()
}

@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    val logsViewModel: LogsViewModel = viewModel()
    val settingsViewModel: SettingsViewModel = viewModel()
    val gc = LocalGhostColors.current

    var overlay by remember { mutableStateOf<Overlay>(Overlay.None) }

    Box(
        Modifier
            .fillMaxSize()
            .background(gc.pageBase),
    ) {
        NavHost(navController, startDestination = "dashboard") {
            composable("dashboard") {
                DashboardScreen(
                    onOpenLogs = { overlay = Overlay.Logs },
                    onOpenSettings = { overlay = Overlay.Settings },
                )
            }

            composable("qr_scanner") {
                QrScannerScreen(
                    onResult = { result ->
                        settingsViewModel.setPendingConnString(result)
                        overlay = Overlay.Settings
                        navController.popBackStack()
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable("qr_scanner_pair/{profileId}") { backEntry ->
                val profileId = backEntry.arguments?.getString("profileId") ?: return@composable
                QrScannerScreen(
                    onResult = { qrText ->
                        settingsViewModel.sendToTv(profileId, qrText)
                        overlay = Overlay.Settings
                        navController.popBackStack()
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            composable("tv_pairing") {
                TvPairingScreen(onDone = { navController.popBackStack() })
            }
        }

        // ── Overlays ────────────────────────────────────────────────────────

        // Logs overlay
        GhostOverlay(
            visible = overlay is Overlay.Logs,
            onDismiss = { overlay = Overlay.None },
            title = "Логи",
            titleColor = BlueDebug,
            titleIcon = {
                Icon(
                    Icons.AutoMirrored.Filled.Article,
                    null,
                    tint = BlueDebug,
                    modifier = Modifier.then(Modifier),
                )
            },
            gradientStart = gc.logsSheetStart,
            gradientEnd = gc.logsSheetEnd,
        ) {
            LogsScreen(viewModel = logsViewModel)
        }

        // Settings overlay
        GhostOverlay(
            visible = overlay is Overlay.Settings,
            onDismiss = { overlay = Overlay.None },
            title = "Параметры",
            titleColor = AccentPurple,
            titleIcon = {
                Icon(
                    Icons.Filled.Settings,
                    null,
                    tint = AccentPurple,
                    modifier = Modifier.then(Modifier),
                )
            },
            gradientStart = gc.settSheetStart,
            gradientEnd = gc.settSheetEnd,
        ) {
            SettingsScreen(
                viewModel = settingsViewModel,
                onNavigateToQrScanner = { navController.navigate("qr_scanner") },
                onAdminNavigate = { profileId ->
                    val profiles = settingsViewModel.profiles.value
                    val profile = profiles.find { it.id == profileId }
                    val url = profile?.adminUrl
                    val token = profile?.adminToken
                    if (url != null && token != null) {
                        overlay = Overlay.Admin(url, token)
                    }
                },
                onShareToTv = { profileId -> navController.navigate("qr_scanner_pair/$profileId") },
                onGetFromPhone = { navController.navigate("tv_pairing") },
                onOpenAddServer = { overlay = Overlay.AddServer },
                onOpenDns = { overlay = Overlay.Dns },
                onOpenApps = { overlay = Overlay.Apps },
                onOpenRoutes = { overlay = Overlay.Routes },
            )
        }

        // Admin overlay
        val adminOv = overlay as? Overlay.Admin
        GhostOverlay(
            visible = adminOv != null,
            onDismiss = { overlay = Overlay.Settings },
            title = "Администрирование",
            gradientStart = gc.adminSheetStart,
            gradientEnd = gc.adminSheetEnd,
        ) {
            if (adminOv != null) {
                AdminScreen(
                    adminUrl = adminOv.adminUrl,
                    adminToken = adminOv.adminToken,
                    onBack = { overlay = Overlay.Settings },
                )
            }
        }

        // Add Server overlay
        GhostOverlay(
            visible = overlay is Overlay.AddServer,
            onDismiss = { overlay = Overlay.Settings },
            title = "Добавить подключение",
            gradientStart = com.ghoststream.vpn.ui.theme.AddServerSheetStart,
            gradientEnd = com.ghoststream.vpn.ui.theme.AddServerSheetEnd,
        ) {
            AddServerOverlay(
                viewModel = settingsViewModel,
                onQrScanner = { navController.navigate("qr_scanner") },
                onDone = { overlay = Overlay.Settings },
            )
        }

        // DNS overlay
        GhostOverlay(
            visible = overlay is Overlay.Dns,
            onDismiss = { overlay = Overlay.Settings },
            title = "DNS стек",
            titleColor = com.ghoststream.vpn.ui.theme.AccentTeal,
            gradientStart = com.ghoststream.vpn.ui.theme.DnsSheetStart,
            gradientEnd = com.ghoststream.vpn.ui.theme.DnsSheetEnd,
        ) {
            DnsOverlay(viewModel = settingsViewModel)
        }

        // Apps overlay
        GhostOverlay(
            visible = overlay is Overlay.Apps,
            onDismiss = { overlay = Overlay.Settings },
            title = "Приложения",
            titleColor = AccentPurple,
            gradientStart = com.ghoststream.vpn.ui.theme.AppsSheetStart,
            gradientEnd = com.ghoststream.vpn.ui.theme.AppsSheetEnd,
        ) {
            AppsOverlay(viewModel = settingsViewModel)
        }

        // Routes overlay
        GhostOverlay(
            visible = overlay is Overlay.Routes,
            onDismiss = { overlay = Overlay.Settings },
            title = "Маршрутизация",
            titleColor = com.ghoststream.vpn.ui.theme.YellowWarning,
            gradientStart = com.ghoststream.vpn.ui.theme.RoutesSheetStart,
            gradientEnd = com.ghoststream.vpn.ui.theme.RoutesSheetEnd,
        ) {
            RoutesOverlay(viewModel = settingsViewModel)
        }
    }
}
