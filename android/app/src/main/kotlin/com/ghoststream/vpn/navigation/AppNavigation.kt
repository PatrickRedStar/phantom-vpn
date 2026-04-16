package com.ghoststream.vpn.navigation

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.ghoststream.vpn.R
import com.ghoststream.vpn.ui.admin.AdminScreen
import com.ghoststream.vpn.ui.components.GhostBottomNav
import com.ghoststream.vpn.ui.components.NavEntry
import com.ghoststream.vpn.ui.components.QrScannerScreen
import com.ghoststream.vpn.ui.dashboard.DashboardScreen
import com.ghoststream.vpn.ui.logs.LogsScreen
import com.ghoststream.vpn.ui.logs.LogsViewModel
import com.ghoststream.vpn.ui.pairing.TvPairingScreen
import com.ghoststream.vpn.ui.settings.SettingsScreen
import com.ghoststream.vpn.ui.settings.SettingsViewModel
import com.ghoststream.vpn.ui.theme.C
import kotlinx.coroutines.launch

@Composable
fun AppNavigation() {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route

    val logsViewModel: LogsViewModel = viewModel()
    val settingsViewModel: SettingsViewModel = viewModel()

    val bottomRoutes = listOf("dashboard", "logs", "settings")

    val entries = listOf(
        NavEntry(route = "dashboard",   glyph = "◉", label = stringResource(R.string.nav_stream)),
        NavEntry(route = "logs",        glyph = "▤", label = stringResource(R.string.nav_logs)),
        NavEntry(route = "settings",    glyph = "⚙", label = stringResource(R.string.nav_settings)),
    )

    val pagerState = rememberPagerState(pageCount = { 3 })
    val scope = rememberCoroutineScope()

    val isOnTabRoute = currentRoute == null || currentRoute == "tabs"

    // Forward QR/pairing results from NavHost savedStateHandle to settingsViewModel
    val tabsEntry = navBackStackEntry
    if (tabsEntry != null && currentRoute == "tabs") {
        val qrResult = tabsEntry.savedStateHandle.get<String>("qr_result")
        if (qrResult != null) {
            settingsViewModel.setPendingConnString(qrResult)
            tabsEntry.savedStateHandle.remove<String>("qr_result")
        }
        val pairResult = tabsEntry.savedStateHandle.get<String>("pair_qr_result")
        if (pairResult != null) {
            val parts = pairResult.split("|||", limit = 2)
            if (parts.size == 2) settingsViewModel.sendToTv(parts[0], parts[1])
            tabsEntry.savedStateHandle.remove<String>("pair_qr_result")
        }
    }

    // When returning from sub-route to "tabs", scroll pager to Settings (page 2)
    // if there's a pending QR result (user just scanned a QR)
    LaunchedEffect(currentRoute) {
        if (currentRoute == "tabs" && pagerState.currentPage != 2) {
            val hasResult = tabsEntry?.savedStateHandle?.get<String>("qr_result") != null
            if (hasResult) pagerState.animateScrollToPage(2)
        }
    }

    Box(Modifier.fillMaxSize().background(C.bg)) {
        // Main tab pager — always composed to preserve state
        HorizontalPager(
            state = pagerState,
            modifier = Modifier
                .fillMaxSize()
                .windowInsetsPadding(WindowInsets.statusBars),
            beyondViewportPageCount = 2,
            userScrollEnabled = isOnTabRoute,
        ) { page ->
            when (page) {
                0 -> DashboardScreen()
                1 -> LogsScreen(viewModel = logsViewModel)
                2 -> SettingsScreen(
                    viewModel = settingsViewModel,
                    onNavigateToQrScanner = { navController.navigate("qr_scanner") },
                    onAdminNavigate = { profileId -> navController.navigate("admin/$profileId") },
                    onShareToTv = { profileId -> navController.navigate("qr_scanner_pair/$profileId") },
                    onGetFromPhone = { navController.navigate("tv_pairing") },
                )
            }
        }

        // NavHost for non-tab routes (overlays pager when active)
        NavHost(
            navController,
            startDestination = "tabs",
            Modifier.fillMaxSize(),
        ) {
            composable("tabs") { /* empty — pager handles tab content */ }

            composable("admin_root") { entry ->
                val vm: SettingsViewModel = viewModel(entry)
                val profiles by vm.profiles.collectAsStateWithLifecycle()
                val activeId by vm.activeProfileId.collectAsStateWithLifecycle()
                val adminProfile = profiles.firstOrNull { it.id == activeId && it.cachedIsAdmin == true }
                    ?: profiles.firstOrNull { it.cachedIsAdmin == true }
                    ?: profiles.firstOrNull { it.id == activeId }
                    ?: profiles.firstOrNull()
                if (adminProfile != null) {
                    AdminScreen(
                        profile = adminProfile,
                        onBack = {
                            navController.popBackStack("tabs", inclusive = false)
                        },
                    )
                }
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
                val profile = settingsViewModel.profiles.collectAsStateWithLifecycle().value
                    .find { it.id == profileId }
                if (profile != null) {
                    AdminScreen(
                        profile = profile,
                        onBack = { navController.popBackStack() },
                    )
                }
            }
        }

        // Bottom nav — visible only on tab routes
        if (isOnTabRoute) {
            GhostBottomNav(
                entries = entries,
                currentRoute = bottomRoutes.getOrNull(pagerState.currentPage) ?: "dashboard",
                onSelect = { route ->
                    val idx = bottomRoutes.indexOf(route)
                    if (idx >= 0) scope.launch { pagerState.animateScrollToPage(idx) }
                },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}
