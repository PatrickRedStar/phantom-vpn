package com.ghoststream.vpn.ui.settings

import android.content.ClipboardManager
import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.LocalGhostColors

@Composable
fun AddServerOverlay(
    viewModel: SettingsViewModel,
    onQrScanner: () -> Unit,
    onDone: () -> Unit,
) {
    val gc = LocalGhostColors.current
    val context = LocalContext.current
    val connString by viewModel.pendingConnString.collectAsStateWithLifecycle()
    val pendingName by viewModel.pendingName.collectAsStateWithLifecycle()
    val importStatus by viewModel.importStatus.collectAsStateWithLifecycle()
    val isReady = connString.isNotBlank()

    Column(
        modifier = Modifier
            .testTag("overlay_add_server")
            .verticalScroll(rememberScrollState()),
    ) {
        // Kicker
        Text(
            "Импорт хоста",
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 1.1.sp,
            color = gc.textTertiary,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "Вставьте строку подключения или отсканируйте QR-код для быстрого добавления.",
            fontSize = 11.sp,
            color = gc.textSecondary,
            lineHeight = 15.5.sp,
        )

        Spacer(Modifier.height(16.dp))

        // Panel 1: Alias
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(18.dp))
                .padding(14.dp),
        ) {
            Text(
                "Название",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.9.sp,
                color = gc.textTertiary,
            )
            Spacer(Modifier.height(10.dp))
            BasicTextField(
                value = pendingName,
                onValueChange = { viewModel.setPendingName(it) },
                singleLine = true,
                textStyle = TextStyle(
                    fontSize = 13.sp,
                    color = gc.textPrimary,
                ),
                cursorBrush = SolidColor(AccentPurple),
                decorationBox = { inner ->
                    if (pendingName.isEmpty()) {
                        Text("Мой VPN", fontSize = 13.sp, color = gc.textTertiary.copy(alpha = 0.52f))
                    }
                    inner()
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color.White.copy(alpha = 0.05f))
                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
                    .padding(14.dp),
            )
        }

        Spacer(Modifier.height(12.dp))

        // Panel 2: Connection string
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(18.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(18.dp))
                .padding(14.dp),
        ) {
            Text(
                "Строка подключения",
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.9.sp,
                color = gc.textTertiary,
            )
            Spacer(Modifier.height(10.dp))
            BasicTextField(
                value = connString,
                onValueChange = { viewModel.setPendingConnString(it) },
                textStyle = TextStyle(
                    fontSize = 12.sp,
                    color = gc.textPrimary,
                ),
                cursorBrush = SolidColor(AccentPurple),
                decorationBox = { inner ->
                    if (connString.isEmpty()) {
                        Text(
                            "eyJ0eXAiOiJKV1QiLCJhbGci...",
                            fontSize = 12.sp,
                            color = gc.textTertiary.copy(alpha = 0.52f),
                        )
                    }
                    inner()
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(92.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color.White.copy(alpha = 0.05f))
                    .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
                    .padding(14.dp),
            )
        }

        Spacer(Modifier.height(12.dp))

        // Tools row
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            GhostButton("Из буфера", Modifier.weight(1f)) {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = cm.primaryClip?.getItemAt(0)?.text?.toString()
                if (!clip.isNullOrBlank()) viewModel.setPendingConnString(clip)
            }
            GhostButton("QR-код", Modifier.weight(1f)) {
                onQrScanner()
            }
        }

        // Status
        if (importStatus.isNotBlank()) {
            Spacer(Modifier.height(8.dp))
            Text(
                importStatus,
                fontSize = 11.sp,
                color = if (importStatus.startsWith("Ошибка")) Color(0xFFfb7185) else AccentPurple,
            )
        }

        Spacer(Modifier.height(16.dp))

        // Footer: Cancel + Add
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Отмена",
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color(0xFFa999ff),
                modifier = Modifier
                    .testTag("add_server_cancel")
                    .clickable(onClick = onDone)
                    .padding(10.dp),
            )
            val btnBg = if (isReady) {
                Brush.linearGradient(listOf(Color(0xFF7c6af7), Color(0xFF9f7cff)))
            } else {
                Brush.linearGradient(listOf(Color.White.copy(alpha = 0.08f), Color.White.copy(alpha = 0.08f)))
            }
            val btnBorder = if (isReady) AccentPurple.copy(alpha = 0.34f) else Color.White.copy(alpha = 0.08f)
            val btnTextColor = if (isReady) Color.White else Color.White.copy(alpha = 0.42f)

            Text(
                "Добавить",
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
                color = btnTextColor,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .testTag("add_server_submit")
                    .clip(RoundedCornerShape(14.dp))
                    .background(btnBg)
                    .border(0.5.dp, btnBorder, RoundedCornerShape(14.dp))
                    .then(
                        if (isReady) Modifier.clickable {
                            viewModel.importConfig()
                            onDone()
                        } else Modifier
                    )
                    .padding(horizontal = 18.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun GhostButton(text: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val gc = LocalGhostColors.current
    Text(
        text = text,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        color = gc.textSecondary,
        textAlign = TextAlign.Center,
        modifier = modifier
            .testTag(
                when (text) {
                    "Из буфера" -> "add_server_paste"
                    "QR-код" -> "add_server_qr"
                    else -> "add_server_button"
                }
            )
            .clip(RoundedCornerShape(14.dp))
            .background(Color.White.copy(alpha = 0.05f))
            .border(0.5.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
    )
}
