package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.LocalGhostColors
import kotlinx.coroutines.delay

@Composable
fun MiniToast(
    message: String?,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
    isDanger: Boolean = false,
) {
    val gc = LocalGhostColors.current
    var show by remember { mutableStateOf(false) }

    LaunchedEffect(message) {
        if (message != null) {
            show = true
            delay(2000)
            show = false
            delay(250)
            onDismiss()
        }
    }

    val alpha by animateFloatAsState(
        targetValue = if (show) 1f else 0f,
        animationSpec = tween(220),
        label = "toast",
    )

    if (message != null && alpha > 0f) {
        Box(
            modifier = modifier.fillMaxWidth(),
            contentAlignment = Alignment.BottomCenter,
        ) {
            Text(
                text = message,
                fontSize = 11.sp,
                color = if (isDanger) Color(0xFFFECDD3) else gc.textPrimary,
                modifier = Modifier
                    .graphicsLayer {
                        this.alpha = alpha
                        translationY = (1f - alpha) * 16f
                    }
                    .background(
                        gc.miniToastBg,
                        RoundedCornerShape(14.dp),
                    )
                    .border(
                        0.5.dp,
                        if (isDanger) Color(0x47FB7185) else gc.cardBorder,
                        RoundedCornerShape(14.dp),
                    )
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            )
        }
    }
}

private object Color {
    operator fun invoke(argb: Long) = androidx.compose.ui.graphics.Color(argb)
}
