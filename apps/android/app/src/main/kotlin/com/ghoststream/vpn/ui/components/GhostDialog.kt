package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Box
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.window.SecureFlagPolicy
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsShapeCard
import com.ghoststream.vpn.ui.theme.GsShapeField
import com.ghoststream.vpn.ui.theme.GsText

// ── GhostDialog ─────────────────────────────────────────────────────────────

@Composable
fun GhostDialog(
    onDismissRequest: () -> Unit,
    title: String,
    content: @Composable ColumnScope.() -> Unit,
    confirmButton: @Composable (() -> Unit)? = null,
    dismissButton: @Composable (() -> Unit)? = null,
    /** FLAG_SECURE: keep secrets (keys, QR with a key) out of screenshots and recents. */
    secure: Boolean = false,
) {
    Dialog(
        onDismissRequest = onDismissRequest,
        properties = DialogProperties(
            securePolicy = if (secure) SecureFlagPolicy.SecureOn else SecureFlagPolicy.Inherit,
        ),
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .clip(GsShapeCard)
                .background(C.bgElev2)
                .border(1.dp, C.bone.copy(alpha = 0.07f), GsShapeCard)
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
                        Spacer(Modifier.width(8.dp))
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
                .clip(GsShapeCard)
                .background(C.bgElev2)
                .border(1.dp, C.bone.copy(alpha = 0.07f), GsShapeCard)
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
                        Spacer(Modifier.width(8.dp))
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
    // ADR 0015: кнопка диалога должна ВЫГЛЯДЕТЬ кнопкой. Голый текст был
    // неинформативен (баг-репорт 2026-08-01). Роль выводим из color, чтобы не
    // трогать ~20 call site'ов: signal → filled, danger → outlined-danger,
    // остальное → tonal.
    val pill = com.ghoststream.vpn.ui.theme.GsShapePill
    val isPrimary = color == C.signal
    val isDanger = color == C.danger
    val bg = when {
        !enabled       -> C.bone.copy(alpha = 0.04f)
        isPrimary      -> C.signal
        isDanger       -> C.danger.copy(alpha = 0.10f)
        else           -> C.bone.copy(alpha = 0.06f)
    }
    val fg = when {
        !enabled  -> C.textFaint
        isPrimary -> C.bg
        else      -> color
    }
    Box(
        Modifier
            .clip(pill)
            .background(bg)
            .then(
                if (isDanger && enabled)
                    Modifier.border(1.dp, C.danger.copy(alpha = 0.45f), pill)
                else Modifier,
            )
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text.uppercase(),
            style = GsText.labelMono,
            color = fg,
            maxLines = 1,
            softWrap = false, // «СОХР/АНИТ/Ь» в 3 строки — тот же баг-репорт
        )
    }
}

// ── Ghost-styled TextField helpers ──────────────────────────────────────────

val GhostTextFieldShape = GsShapeField

@Composable
fun ghostTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = C.bone,
    unfocusedTextColor = C.bone,
    cursorColor = C.signal,
    focusedBorderColor = C.signal,
    unfocusedBorderColor = C.hairBold,
    focusedLabelColor = C.signal,
    unfocusedLabelColor = C.textDim,
    focusedContainerColor = C.bgElev2,
    unfocusedContainerColor = C.bgElev2,
)
