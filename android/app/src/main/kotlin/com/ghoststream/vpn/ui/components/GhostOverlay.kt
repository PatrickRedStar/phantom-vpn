package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.LocalGhostColors

@Composable
fun GhostOverlay(
    visible: Boolean,
    onDismiss: () -> Unit,
    title: String,
    titleColor: Color = LocalGhostColors.current.textPrimary,
    titleIcon: (@Composable () -> Unit)? = null,
    gradientStart: Color = LocalGhostColors.current.sheetGradStart,
    gradientEnd: Color = LocalGhostColors.current.sheetGradEnd,
    actions: (@Composable () -> Unit)? = null,
    maxWidthDp: Int = 324,
    content: @Composable () -> Unit,
) {
    val gc = LocalGhostColors.current
    var show by remember { mutableStateOf(false) }

    LaunchedEffect(visible) { show = visible }

    val animProgress by animateFloatAsState(
        targetValue = if (show) 1f else 0f,
        animationSpec = tween(280),
        label = "overlay",
    )

    if (animProgress == 0f && !visible) return

    val screenH = LocalConfiguration.current.screenHeightDp

    Box(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer { alpha = animProgress },
        contentAlignment = Alignment.Center,
    ) {
        // Backdrop
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(gc.overlayBackdrop)
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onDismiss,
                ),
        )

        // Sheet
        Column(
            modifier = Modifier
                .padding(horizontal = 18.dp)
                .fillMaxWidth()
                .heightIn(max = (screenH * 0.82f).dp)
                .graphicsLayer {
                    val t = animProgress
                    translationY = (1f - t) * 54f
                    scaleX = 0.94f + 0.06f * t
                    scaleY = 0.94f + 0.06f * t
                    alpha = t
                }
                .clip(RoundedCornerShape(30.dp))
                .background(
                    Brush.verticalGradient(listOf(gradientStart, gradientEnd))
                )
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = {},  // consume clicks on sheet
                ),
        ) {
            // Header
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 18.dp, end = 18.dp, top = 18.dp, bottom = 14.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    titleIcon?.invoke()
                    Text(
                        text = title,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = titleColor,
                    )
                }
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    actions?.invoke()
                    // Close button
                    Box(
                        modifier = Modifier
                            .size(30.dp)
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.08f))
                            .clickable(onClick = onDismiss),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("✕", fontSize = 13.sp, color = gc.textSecondary)
                    }
                }
            }

            // Body — scrollable
            Column(
                modifier = Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(start = 16.dp, end = 16.dp, bottom = 18.dp),
            ) {
                content()
            }
        }
    }
}
