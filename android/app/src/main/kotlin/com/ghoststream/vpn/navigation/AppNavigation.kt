package com.ghoststream.vpn.navigation

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ghoststream.vpn.ui.admin.AdminScreen
import com.ghoststream.vpn.ui.components.QrScannerScreen
import com.ghoststream.vpn.ui.dashboard.DashboardScreen
import com.ghoststream.vpn.ui.logs.LogsScreen
import com.ghoststream.vpn.ui.logs.LogsViewModel
import com.ghoststream.vpn.ui.pairing.TvPairingScreen
import com.ghoststream.vpn.ui.settings.SettingsScreen
import com.ghoststream.vpn.ui.settings.SettingsViewModel

private data class NavItem(val route: String, val icon: ImageVector, val label: String)

private val NAV_ITEMS = listOf(
    NavItem("dashboard", Icons.Filled.Security, "Главная"),
    NavItem("logs",      Icons.Filled.Code,     "Логи"),
    NavItem("settings",  Icons.Filled.Settings, "Настройки"),
)

@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    val logsViewModel: LogsViewModel = viewModel()

    val showBottomBar = currentRoute in listOf("dashboard", "logs", "settings")

    // Scaffold только для системных отступов, без стандартного NavigationBar
    Scaffold(
        bottomBar = {
            // Резервируем место под floating bar
            if (showBottomBar) Spacer(Modifier.height(80.dp).navigationBarsPadding())
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        Box(Modifier.fillMaxSize()) {
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
                composable("tv_pairing") {
                    TvPairingScreen(onDone = { navController.popBackStack() })
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

            // Floating liquid glass navigation bar
            if (showBottomBar) {
                LiquidGlassNavBar(
                    currentRoute = currentRoute,
                    onNavigate = { route ->
                        navController.navigate(route) {
                            popUpTo("dashboard") { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                    },
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp, vertical = 12.dp)
                        .navigationBarsPadding(),
                )
            }
        }
    }
}

@Composable
private fun LiquidGlassNavBar(
    currentRoute: String?,
    onNavigate: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(28.dp))
            .background(Color(0xF0161622))
            .padding(horizontal = 6.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        NAV_ITEMS.forEach { item ->
            val selected = currentRoute == item.route

            val bgColor by animateColorAsState(
                targetValue = if (selected) Color(0xFF2A2A3C) else Color.Transparent,
                animationSpec = tween(200),
                label = "nav_bg_${item.route}",
            )
            val contentColor by animateColorAsState(
                targetValue = if (selected) Color.White else Color(0xFF7A7A9A),
                animationSpec = tween(200),
                label = "nav_fg_${item.route}",
            )

            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(22.dp))
                    .background(bgColor)
                    .clickable { onNavigate(item.route) }
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        imageVector = item.icon,
                        contentDescription = item.label,
                        tint = contentColor,
                        modifier = Modifier.size(22.dp),
                    )
                    Spacer(Modifier.height(3.dp))
                    Text(
                        text = item.label,
                        style = MaterialTheme.typography.labelSmall,
                        color = contentColor,
                        fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
                    )
                }
            }
        }
    }
}
