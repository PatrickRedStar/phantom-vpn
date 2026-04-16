package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText

// ── GhostDialog ─────────────────────────────────────────────────────────────

@Composable
fun GhostDialog(
    onDismissRequest: () -> Unit,
    title: String,
    content: @Composable ColumnScope.() -> Unit,
    confirmButton: @Composable (() -> Unit)? = null,
    dismissButton: @Composable (() -> Unit)? = null,
) {
    Dialog(onDismissRequest = onDismissRequest) {
        Column(
            Modifier
                .fillMaxWidth()
                .background(C.bgElev)
                .border(1.dp, C.hair)
                .padding(20.dp),
        ) {
            Text(title.uppercase(), style = GsText.labelMono, color = C.bone)
            SolidHairline(Modifier.padding(vertical = 12.dp))
            content()
            if (confirmButton != null || dismissButton != null) {
                Spacer(Modifier.height(16.dp))
                SolidHairline()
                Spacer(Modifier.height(12.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    dismissButton?.invoke()
                    if (dismissButton != null && confirmButton != null) {
                        Spacer(Modifier.width(12.dp))
                    }
                    confirmButton?.invoke()
                }
            }
        }
    }
}

// ── GhostFullDialog ─────────────────────────────────────────────────────────

@Composable
fun GhostFullDialog(
    onDismissRequest: () -> Unit,
    title: String,
    content: @Composable ColumnScope.() -> Unit,
    confirmButton: @Composable (() -> Unit)? = null,
    dismissButton: @Composable (() -> Unit)? = null,
) {
    Dialog(
        onDismissRequest = onDismissRequest,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Column(
            Modifier
                .fillMaxWidth(0.95f)
                .fillMaxHeight(0.8f)
                .background(C.bgElev)
                .border(1.dp, C.hair)
                .padding(20.dp),
        ) {
            Text(title.uppercase(), style = GsText.labelMono, color = C.bone)
            SolidHairline(Modifier.padding(vertical = 12.dp))
            Column(Modifier.weight(1f)) {
                content()
            }
            if (confirmButton != null || dismissButton != null) {
                Spacer(Modifier.height(16.dp))
                SolidHairline()
                Spacer(Modifier.height(12.dp))
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.End,
                ) {
                    dismissButton?.invoke()
                    if (dismissButton != null && confirmButton != null) {
                        Spacer(Modifier.width(12.dp))
                    }
                    confirmButton?.invoke()
                }
            }
        }
    }
}

// ── GhostDialogButton ───────────────────────────────────────────────────────

@Composable
fun GhostDialogButton(
    text: String,
    onClick: () -> Unit,
    color: Color = C.signal,
    enabled: Boolean = true,
) {
    Text(
        text.uppercase(),
        style = GsText.labelMono,
        color = if (enabled) color else C.textFaint,
        modifier = Modifier
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 8.dp),
    )
}

// ── Ghost-styled TextField helpers ──────────────────────────────────────────

val GhostTextFieldShape = RectangleShape

@Composable
fun ghostTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = C.bone,
    unfocusedTextColor = C.bone,
    cursorColor = C.signal,
    focusedBorderColor = C.signal,
    unfocusedBorderColor = C.hairBold,
    focusedLabelColor = C.signal,
    unfocusedLabelColor = C.textDim,
    focusedContainerColor = C.bg,
    unfocusedContainerColor = C.bg,
)
