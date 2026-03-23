package com.ghoststream.vpn.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.ghoststream.vpn.ui.admin.AdminSheet
import com.ghoststream.vpn.ui.components.QrScannerScreen
import com.ghoststream.vpn.ui.dashboard.DashboardScreen
import com.ghoststream.vpn.ui.logs.LogsSheet
import com.ghoststream.vpn.ui.logs.LogsViewModel
import com.ghoststream.vpn.ui.pairing.TvPairingScreen
import com.ghoststream.vpn.ui.settings.SettingsSheet
import com.ghoststream.vpn.ui.settings.SettingsViewModel
import com.ghoststream.vpn.ui.theme.PageBase

// Which overlay is currently shown
private sealed class Overlay {
    object None : Overlay()
    object Logs : Overlay()
    object Settings : Overlay()
    data class Admin(val adminUrl: String, val adminToken: String) : Overlay()
}

@Composable
fun AppNavigation() {
    val navController      = rememberNavController()
    val logsViewModel: LogsViewModel         = viewModel()
    val settingsViewModel: SettingsViewModel = viewModel()

    var overlay by remember { mutableStateOf<Overlay>(Overlay.None) }

    Box(
        Modifier
            .fillMaxSize()
            .background(PageBase),
    ) {
        NavHost(navController, startDestination = "dashboard") {
            composable("dashboard") {
                DashboardScreen(
                    onOpenLogs     = { overlay = Overlay.Logs },
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

        // ── Overlays ──────────────────────────────────────────────────────────
        when (val ov = overlay) {
            is Overlay.Logs -> LogsSheet(
                onDismiss  = { overlay = Overlay.None },
                viewModel  = logsViewModel,
            )

            is Overlay.Settings -> SettingsSheet(
                onDismiss              = { overlay = Overlay.None },
                viewModel              = settingsViewModel,
                onNavigateToQrScanner  = { navController.navigate("qr_scanner") },
                onAdminNavigate        = { profileId ->
                    val profiles = settingsViewModel.profiles.value
                    val profile  = profiles.find { it.id == profileId }
                    val url   = profile?.adminUrl
                    val token = profile?.adminToken
                    if (url != null && token != null) {
                        overlay = Overlay.Admin(url, token)
                    }
                },
                onShareToTv   = { profileId -> navController.navigate("qr_scanner_pair/$profileId") },
                onGetFromPhone = { navController.navigate("tv_pairing") },
            )

            is Overlay.Admin -> AdminSheet(
                adminUrl   = ov.adminUrl,
                adminToken = ov.adminToken,
                onDismiss  = { overlay = Overlay.Settings },   // back → settings
            )

            is Overlay.None -> Unit
        }
    }
}
