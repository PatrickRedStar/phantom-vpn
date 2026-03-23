package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.CardBg
import com.ghoststream.vpn.ui.theme.CardBorder
import com.ghoststream.vpn.ui.theme.TextPrimary
import com.ghoststream.vpn.ui.theme.TextTertiary

@Composable
fun StatCard(
    icon: ImageVector,
    label: String,
    value: String,
    subValue: String? = null,
    iconTint: Color,
    iconBg: Color,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(CardBg)
            .border(0.5.dp, CardBorder, RoundedCornerShape(14.dp))
            .padding(12.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(
                contentAlignment = Alignment.Center,
                modifier = Modifier
                    .size(20.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(iconBg),
            ) {
                Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(11.dp))
            }
            Text(text = label, style = MaterialTheme.typography.labelSmall, color = TextTertiary)
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = value,
            style = MaterialTheme.typography.titleMedium.copy(fontFamily = FontFamily.Monospace),
            color = TextPrimary,
        )
        if (subValue != null) {
            Text(
                text = subValue,
                style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                color = TextTertiary,
            )
        }
    }
}
