package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.AccentPurple
import com.ghoststream.vpn.ui.theme.AccentTeal
import com.ghoststream.vpn.ui.theme.YellowWarning

enum class BadgeVariant { DEFAULT, ALT, WARN }

@Composable
fun GhostBadge(
    text: String,
    variant: BadgeVariant = BadgeVariant.DEFAULT,
    modifier: Modifier = Modifier,
) {
    val (fg, bg, border) = when (variant) {
        BadgeVariant.DEFAULT -> Triple(
            AccentPurple,
            AccentPurple.copy(alpha = 0.1f),
            AccentPurple.copy(alpha = 0.24f),
        )
        BadgeVariant.ALT -> Triple(
            AccentTeal,
            AccentTeal.copy(alpha = 0.1f),
            AccentTeal.copy(alpha = 0.24f),
        )
        BadgeVariant.WARN -> Triple(
            YellowWarning,
            YellowWarning.copy(alpha = 0.1f),
            YellowWarning.copy(alpha = 0.24f),
        )
    }

    Text(
        text = text,
        fontSize = 10.sp,
        fontWeight = FontWeight.Bold,
        letterSpacing = 0.3.sp,
        color = fg,
        modifier = modifier
            .clip(RoundedCornerShape(999.dp))
            .background(bg)
            .border(1.dp, border, RoundedCornerShape(999.dp))
            .padding(horizontal = 10.dp, vertical = 6.dp),
    )
}
