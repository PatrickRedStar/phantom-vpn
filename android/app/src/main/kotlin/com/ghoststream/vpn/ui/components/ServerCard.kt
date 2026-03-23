package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.CardBg
import com.ghoststream.vpn.ui.theme.CardBorder
import com.ghoststream.vpn.ui.theme.TextPrimary
import com.ghoststream.vpn.ui.theme.TextTertiary

@Composable
fun ServerCard(
    flagEmoji: String,
    host: String,
    subscriptionText: String?,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .clip(RoundedCornerShape(12.dp))
            .background(CardBg)
            .border(0.5.dp, CardBorder, RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(text = flagEmoji, fontSize = 15.sp)
        Column {
            Text(
                text = host,
                style = MaterialTheme.typography.labelMedium.copy(fontFamily = FontFamily.Monospace),
                color = TextPrimary,
            )
            val meta = buildString {
                if (subscriptionText != null) append("$subscriptionText · ")
                append("QUIC")
            }
            Text(
                text = meta,
                style = MaterialTheme.typography.bodySmall,
                color = TextTertiary,
            )
        }
    }
}
