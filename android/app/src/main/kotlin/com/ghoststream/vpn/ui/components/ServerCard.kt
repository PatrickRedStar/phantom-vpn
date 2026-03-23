package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.LocalGhostColors

@Composable
fun ServerCard(
    flagEmoji: String,
    host: String,
    subscriptionText: String?,
    modifier: Modifier = Modifier,
) {
    val gc = LocalGhostColors.current
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(gc.cardBg)
            .border(0.5.dp, gc.cardBorder, RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(text = flagEmoji, fontSize = 15.sp)
        Column {
            Text(
                text = host,
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                color = gc.textSecondary,
            )
            val meta = buildString {
                if (subscriptionText != null) append("$subscriptionText · ")
                append("QUIC")
            }
            Text(
                text = meta,
                fontSize = 10.sp,
                color = gc.textTertiary,
            )
        }
    }
}
