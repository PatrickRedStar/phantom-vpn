package com.ghoststream.vpn.ui.pairing

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ghoststream.vpn.ui.theme.GreenConnected
import com.ghoststream.vpn.ui.theme.RedError
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter

@Composable
fun TvPairingScreen(
    onDone: () -> Unit = {},
    viewModel: TvPairingViewModel = viewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()

    LaunchedEffect(state) {
        if (state is TvPairingState.Received) {
            kotlinx.coroutines.delay(2_000)
            onDone()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        contentAlignment = Alignment.Center,
    ) {
        when (val s = state) {
            is TvPairingState.Idle -> CircularProgressIndicator()

            is TvPairingState.Ready -> ReadyContent(s.qrJson)

            is TvPairingState.Received -> ReceivedContent()

            is TvPairingState.Timeout -> ErrorContent(
                message = "Время ожидания вышло",
                onRetry = { viewModel.start() },
            )

            is TvPairingState.Error -> ErrorContent(
                message = s.message,
                onRetry = { viewModel.start() },
            )
        }
    }
}

@Composable
private fun ReadyContent(qrJson: String) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.padding(32.dp),
    ) {
        Text(
            "Подключение с телефона",
            style = MaterialTheme.typography.headlineMedium,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Откройте GhostStream на телефоне\n→ Настройки → нажмите  на профиле\n→ Наведите камеру на этот QR-код",
            style = MaterialTheme.typography.bodyMedium,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(32.dp))
        QrCodeImage(content = qrJson, size = 280.dp)
        Spacer(Modifier.height(24.dp))
        Text(
            "Ожидание сканирования...",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun ReceivedContent() {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(
            Icons.Filled.CheckCircle,
            contentDescription = null,
            tint = GreenConnected,
            modifier = Modifier.size(80.dp),
        )
        Spacer(Modifier.height(16.dp))
        Text(
            "Профиль добавлен!",
            style = MaterialTheme.typography.headlineSmall,
            color = GreenConnected,
        )
    }
}

@Composable
private fun ErrorContent(message: String, onRetry: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.padding(32.dp),
    ) {
        Icon(
            Icons.Filled.Error,
            contentDescription = null,
            tint = RedError,
            modifier = Modifier.size(64.dp),
        )
        Spacer(Modifier.height(16.dp))
        Text(
            message,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            color = RedError,
        )
        Spacer(Modifier.height(24.dp))
        FilledTonalButton(onClick = onRetry) {
            Icon(Icons.Filled.Refresh, null)
            Spacer(Modifier.size(8.dp))
            Text("Повторить")
        }
    }
}

@Composable
fun QrCodeImage(content: String, size: Dp, modifier: Modifier = Modifier) {
    val bitmap = remember(content) {
        runCatching {
            val hints = mapOf(EncodeHintType.MARGIN to 1)
            val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, 512, 512, hints)
            val w = matrix.width
            val h = matrix.height
            val pixels = IntArray(w * h) { i ->
                if (matrix[i % w, i / w]) android.graphics.Color.BLACK
                else android.graphics.Color.WHITE
            }
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bmp.setPixels(pixels, 0, w, 0, 0, w, h)
            bmp.asImageBitmap()
        }.getOrNull()
    }

    if (bitmap != null) {
        Box(
            modifier = modifier
                .size(size)
                .background(Color.White, RoundedCornerShape(12.dp))
                .padding(8.dp),
        ) {
            Image(
                bitmap = bitmap,
                contentDescription = "QR-код",
                modifier = Modifier.fillMaxSize(),
            )
        }
    } else {
        Box(
            modifier = modifier.size(size).background(Color.White, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Text("Ошибка QR", color = Color.Red)
        }
    }
}
