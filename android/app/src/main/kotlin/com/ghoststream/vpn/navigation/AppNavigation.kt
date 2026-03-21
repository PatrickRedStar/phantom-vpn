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
import com.ghoststream.vpn.ui.components.QrScannerScreen
import com.ghoststream.vpn.ui.dashboard.DashboardScreen
import com.ghoststream.vpn.ui.logs.LogsScreen
import com.ghoststream.vpn.ui.logs.LogsViewModel
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
                    settingsViewModel.setConnString(qrResult)
                    entry.savedStateHandle.remove<String>("qr_result")
                }
                SettingsScreen(
                    viewModel = settingsViewModel,
                    onNavigateToQrScanner = { navController.navigate("qr_scanner") },
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
        }
    }
}
