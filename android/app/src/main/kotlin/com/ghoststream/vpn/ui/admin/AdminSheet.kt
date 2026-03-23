package com.ghoststream.vpn.ui.admin

import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.viewmodel.compose.viewModel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AdminSheet(
    adminUrl: String,
    adminToken: String,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = Color(0xFF191B2C).copy(alpha = 0.97f),
        modifier = Modifier.fillMaxHeight(),
    ) {
        AdminScreen(
            adminUrl = adminUrl,
            adminToken = adminToken,
            onBack = onDismiss,
            viewModel = viewModel(),
        )
    }
}
