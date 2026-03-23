package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.CardBorder

@Composable
fun GhostToggle(
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val thumbOffset by animateDpAsState(
        targetValue = if (checked) 18.dp else 0.dp,
        animationSpec = tween(200),
        label = "toggle",
    )

    val trackBg = if (checked) AccentPurple.copy(alpha = 0.4f) else Color.White.copy(alpha = 0.1f)
    val trackBorder = if (checked) AccentPurple.copy(alpha = 0.5f) else CardBorder
    val thumbColor = if (checked) Color.White else Color.White.copy(alpha = 0.4f)

    Box(
        modifier = modifier
            .size(width = 40.dp, height = 22.dp)
            .clip(RoundedCornerShape(11.dp))
            .background(trackBg)
            .border(1.dp, trackBorder, RoundedCornerShape(11.dp))
            .clickable { onCheckedChange(!checked) },
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(
            modifier = Modifier
                .offset(x = 2.dp + thumbOffset)
                .size(16.dp)
                .clip(CircleShape)
                .background(thumbColor),
        )
    }
}
