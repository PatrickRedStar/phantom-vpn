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
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.LocalGhostColors

@Composable
fun StatCard(
    iconChar: String,
    label: String,
    value: String,
    subValue: String? = null,
    iconTint: Color,
    iconBg: Color,
    modifier: Modifier = Modifier,
) {
    val gc = LocalGhostColors.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(14.dp))
            .background(gc.cardBg)
            .border(0.5.dp, gc.cardBorder, RoundedCornerShape(14.dp))
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
                Text(iconChar, fontSize = 11.sp, color = iconTint)
            }
            Text(
                text = label,
                fontSize = 11.sp,
                color = gc.textTertiary,
            )
        }
        Spacer(Modifier.height(6.dp))
        Text(
            text = value,
            fontFamily = FontFamily.Monospace,
            fontSize = 18.sp,
            fontWeight = FontWeight.Medium,
            color = gc.textPrimary,
        )
        if (subValue != null) {
            Spacer(Modifier.height(2.dp))
            Text(
                text = subValue,
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
                color = gc.textTertiary,
            )
        }
    }
}
