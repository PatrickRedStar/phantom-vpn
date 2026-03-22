package com.ghoststream.vpn.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.ui.admin.AdminScreen
import com.ghoststream.vpn.ui.components.QrScannerScreen
import com.ghoststream.vpn.ui.dashboard.DashboardScreen
import com.ghoststream.vpn.ui.logs.LogsScreen
import com.ghoststream.vpn.ui.logs.LogsViewModel
import com.ghoststream.vpn.ui.pairing.TvPairingScreen
import com.ghoststream.vpn.ui.settings.SettingsScreen
import com.ghoststream.vpn.ui.settings.SettingsViewModel

@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    // Scope to Activity so it survives tab switches
    val logsViewModel: LogsViewModel = viewModel()

    val showBottomBar = currentRoute in listOf("dashboard", "logs", "settings")

    Scaffold(
        bottomBar = {
            if (showBottomBar) {
                NavigationBar {
                    NavigationBarItem(
                        icon = { Icon(Icons.Filled.Security, null) },
                        label = { Text("Главная") },
                        selected = currentRoute == "dashboard",
                        onClick = {
                            navController.navigate("dashboard") {
                                popUpTo("dashboard") { inclusive = true }
                                launchSingleTop = true
                            }
                        },
                    )
                    NavigationBarItem(
                        icon = { Icon(Icons.Filled.Code, null) },
                        label = { Text("Логи") },
                        selected = currentRoute == "logs",
                        onClick = {
                            navController.navigate("logs") {
                                popUpTo("dashboard")
                                launchSingleTop = true
                            }
                        },
                    )
                    NavigationBarItem(
                        icon = { Icon(Icons.Filled.Settings, null) },
                        label = { Text("Настройки") },
                        selected = currentRoute == "settings",
                        onClick = {
                            navController.navigate("settings") {
                                popUpTo("dashboard")
                                launchSingleTop = true
                            }
                        },
                    )
                }
            }
        },
    ) { padding ->
        NavHost(navController, startDestination = "dashboard", Modifier.padding(padding)) {
            composable("dashboard") { DashboardScreen() }
            composable("logs") { LogsScreen(viewModel = logsViewModel) }
            composable("settings") { entry ->
                val settingsViewModel: SettingsViewModel = viewModel(entry)
                val qrResult = entry.savedStateHandle.get<String>("qr_result")
                if (qrResult != null) {
                    settingsViewModel.setPendingConnString(qrResult)
                    entry.savedStateHandle.remove<String>("qr_result")
                }
                val pairResult = entry.savedStateHandle.get<String>("pair_qr_result")
                if (pairResult != null) {
                    val (profileId, qrText) = pairResult.split("|||", limit = 2)
                    settingsViewModel.sendToTv(profileId, qrText)
                    entry.savedStateHandle.remove<String>("pair_qr_result")
                }
                SettingsScreen(
                    viewModel = settingsViewModel,
                    onNavigateToQrScanner = { navController.navigate("qr_scanner") },
                    onAdminNavigate = { profileId -> navController.navigate("admin/$profileId") },
                    onShareToTv = { profileId -> navController.navigate("qr_scanner_pair/$profileId") },
                    onGetFromPhone = { navController.navigate("tv_pairing") },
                )
            }
            composable("qr_scanner") {
                QrScannerScreen(
                    onResult = { result ->
                        navController.previousBackStackEntry
                            ?.savedStateHandle?.set("qr_result", result)
                        navController.popBackStack()
                    },
                    onBack = { navController.popBackStack() },
                )
            }
            // QR scanner в режиме pairing (телефон → TV)
            composable("qr_scanner_pair/{profileId}") { backEntry ->
                val profileId = backEntry.arguments?.getString("profileId") ?: return@composable
                QrScannerScreen(
                    onResult = { qrText ->
                        navController.previousBackStackEntry
                            ?.savedStateHandle?.set("pair_qr_result", "$profileId|||$qrText")
                        navController.popBackStack()
                    },
                    onBack = { navController.popBackStack() },
                )
            }

            // TV pairing screen (TV сторона)
            composable("tv_pairing") {
                TvPairingScreen(
                    onDone = { navController.popBackStack() },
                )
            }

            composable("admin/{profileId}") { backEntry ->
                val profileId = backEntry.arguments?.getString("profileId") ?: return@composable
                val settingsViewModel: SettingsViewModel = viewModel()
                val profile = settingsViewModel.profiles.collectAsStateWithLifecycle().value
                    .find { it.id == profileId }
                if (profile?.adminUrl != null && profile.adminToken != null) {
                    AdminScreen(
                        adminUrl = profile.adminUrl,
                        adminToken = profile.adminToken,
                        onBack = { navController.popBackStack() },
                    )
                }
            }
        }
    }
}
