package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.LocalGhostColors

@Composable
fun GhostCard(
    modifier: Modifier = Modifier,
    radius: Dp = 14.dp,
    padding: Dp = 0.dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    val gc = LocalGhostColors.current
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(radius))
            .background(gc.cardBg)
            .border(0.5.dp, gc.cardBorder, RoundedCornerShape(radius))
            .then(if (padding > 0.dp) Modifier.padding(padding) else Modifier),
        content = content,
    )
}
