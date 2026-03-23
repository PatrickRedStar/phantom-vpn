package com.ghoststream.vpn.navigation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
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
import com.ghoststream.vpn.ui.theme.DarkBackground

private data class NavItem(val route: String, val icon: ImageVector, val label: String)

private val NAV_ITEMS = listOf(
    NavItem("dashboard", Icons.Filled.Security, "Главная"),
    NavItem("logs",      Icons.Filled.Code,     "Логи"),
    NavItem("settings",  Icons.Filled.Settings, "Настройки"),
)

// Высота floating bar + нижние отступы — резервируем место в контенте
private val NAV_BAR_CONTENT_PADDING = 60.dp

// Полупрозрачный dark glass цвет для nav bar
private val GlassColor = Color(0xCC0F0F1A)
private val GlassBorder = Color(0x26FFFFFF)  // 15% white
private val GlassSelected = Color(0x30FFFFFF) // 19% white для выбранного item

@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    val logsViewModel: LogsViewModel = viewModel()

    val showBottomBar = currentRoute in listOf("dashboard", "logs", "settings")

    // Скрытие/показ при прокрутке
    var isNavBarVisible by remember { mutableStateOf(true) }

    // При смене вкладки всегда показываем бар
    LaunchedEffect(currentRoute) { isNavBarVisible = true }

    val nestedScrollConnection = remember {
        object : NestedScrollConnection {
            private var accumulated = 0f
            override fun onPostScroll(
                consumed: Offset,
                available: Offset,
                source: NestedScrollSource,
            ): Offset {
                accumulated += consumed.y
                if (accumulated < -40f) { isNavBarVisible = false; accumulated = 0f }
                else if (accumulated > 40f) { isNavBarVisible = true; accumulated = 0f }
                return Offset.Zero
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(DarkBackground),
    ) {
        Scaffold(
            bottomBar = {
                if (showBottomBar) {
                    Spacer(
                        Modifier
                            .height(NAV_BAR_CONTENT_PADDING)
                            .navigationBarsPadding(),
                    )
                }
            },
            containerColor = Color.Transparent,
        ) { padding ->
            Box(
                Modifier
                    .fillMaxSize()
                    .nestedScroll(nestedScrollConnection),
            ) {
                NavHost(
                    navController,
                    startDestination = "dashboard",
                    Modifier.padding(padding),
                ) {
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

                // Floating liquid glass nav bar с анимацией скрытия
                if (showBottomBar) {
                    AnimatedVisibility(
                        visible = isNavBarVisible,
                        enter = slideInVertically(
                            animationSpec = tween(250),
                            initialOffsetY = { it },
                        ) + fadeIn(tween(200)),
                        exit = slideOutVertically(
                            animationSpec = tween(250),
                            targetOffsetY = { it },
                        ) + fadeOut(tween(200)),
                        modifier = Modifier.align(Alignment.BottomCenter),
                    ) {
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
                                .fillMaxWidth()
                                .padding(horizontal = 32.dp, vertical = 6.dp)
                                .navigationBarsPadding(),
                        )
                    }
                }
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
    val pillShape = RoundedCornerShape(50)
    Row(
        modifier = modifier
            .clip(pillShape)
            .background(GlassColor)
            .border(0.5.dp, GlassBorder, pillShape)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        NAV_ITEMS.forEach { item ->
            val selected = currentRoute == item.route

            val contentColor by animateColorAsState(
                targetValue = if (selected) Color.White else Color(0xFF6B6B88),
                animationSpec = tween(220),
                label = "nb_fg",
            )
            val bgColor by animateColorAsState(
                targetValue = if (selected) GlassSelected else Color.Transparent,
                animationSpec = tween(220),
                label = "nb_bg",
            )

            Box(
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(50))
                    .background(bgColor)
                    .clickable { onNavigate(item.route) }
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = item.icon,
                    contentDescription = item.label,
                    tint = contentColor,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
    }
}
