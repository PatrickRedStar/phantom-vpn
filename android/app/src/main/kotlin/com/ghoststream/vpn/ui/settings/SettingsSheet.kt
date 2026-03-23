package com.ghoststream.vpn.ui.settings

import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(
    onDismiss: () -> Unit,
    viewModel: SettingsViewModel,
    onNavigateToQrScanner: () -> Unit,
    onAdminNavigate: (String) -> Unit,
    onShareToTv: (String) -> Unit,
    onGetFromPhone: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Color(0xFF1C1535).copy(alpha = 0.97f),
        modifier = Modifier.fillMaxHeight(0.94f),
    ) {
        SettingsScreen(
            viewModel = viewModel,
            onNavigateToQrScanner = onNavigateToQrScanner,
            onAdminNavigate = onAdminNavigate,
            onShareToTv = onShareToTv,
            onGetFromPhone = onGetFromPhone,
        )
    }
}
