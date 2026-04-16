package com.ghoststream.vpn.ui.components

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText

data class NavEntry(
    val route: String,
    val glyph: String,
    val label: String,
)

@Composable
fun GhostBottomNav(
    entries: List<NavEntry>,
    currentRoute: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val activeIndex = entries.indexOfFirst { it.route == currentRoute }.coerceAtLeast(0)

    val tabCount = entries.size
    // Each tab gets ~80dp width — capsule shrinks with fewer tabs
    val maxCapsuleWidth = (tabCount * 80).dp

    // Capture theme colors for drawBehind (non-composable scope)
    val bgColor = C.bg
    val bgElevColor = C.bgElev
    val hairColor = C.hair
    val signalColor = C.signal

    // Floating capsule — compact, auto-sizes to tab count
    Box(
        modifier = modifier
            .fillMaxWidth()
            .drawBehind {
                // Gradient fade from transparent to bg behind the navbar
                drawRect(
                    brush = Brush.verticalGradient(
                        colors = listOf(
                            Color.Transparent,
                            bgColor.copy(alpha = 0.85f),
                            bgColor,
                        ),
                    ),
                )
            }
            .windowInsetsPadding(WindowInsets.navigationBars)
            .padding(bottom = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        // Animated pill position
        val pillAnimatedIndex by animateFloatAsState(
            targetValue = activeIndex.toFloat(),
            animationSpec = spring(
                dampingRatio = 0.72f,
                stiffness = Spring.StiffnessMediumLow,
            ),
            label = "pillSlide",
        )

        Box(
            modifier = Modifier
                .widthIn(max = maxCapsuleWidth)
                .shadow(
                    elevation = 12.dp,
                    shape = RoundedCornerShape(22.dp),
                    ambientColor = Color.Black.copy(alpha = 0.25f),
                    spotColor = Color.Black.copy(alpha = 0.25f),
                )
                .clip(RoundedCornerShape(22.dp))
                .background(bgElevColor.copy(alpha = 0.96f))
                .drawBehind {
                    // Border
                    drawRoundRect(
                        color = hairColor.copy(alpha = 0.4f),
                        cornerRadius = CornerRadius(22.dp.toPx()),
                        size = size,
                        style = androidx.compose.ui.graphics.drawscope.Stroke(
                            width = 0.5.dp.toPx()
                        ),
                    )
                    // Sliding pill
                    val tabWidth = size.width / tabCount
                    val pillW = tabWidth - 12.dp.toPx()
                    val pillH = size.height - 10.dp.toPx()
                    val pillX = (pillAnimatedIndex * tabWidth) + (tabWidth - pillW) / 2f
                    val pillY = 5.dp.toPx()
                    val pillR = 18.dp.toPx()

                    drawRoundRect(
                        color = signalColor.copy(alpha = 0.10f),
                        topLeft = Offset(pillX, pillY),
                        size = Size(pillW, pillH),
                        cornerRadius = CornerRadius(pillR),
                    )
                },
        ) {
            Row(
                modifier = Modifier
                    .widthIn(max = maxCapsuleWidth)
                    .padding(vertical = 6.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                entries.forEachIndexed { index, entry ->
                    val active = index == activeIndex
                    val interactionSource = remember { MutableInteractionSource() }

                    // Subtle scale bounce
                    val scale by animateFloatAsState(
                        targetValue = if (active) 1.05f else 1.0f,
                        animationSpec = spring(
                            dampingRatio = 0.65f,
                            stiffness = Spring.StiffnessMedium,
                        ),
                        label = "scale",
                    )
                    val labelAlpha by animateFloatAsState(
                        targetValue = if (active) 1f else 0.55f,
                        animationSpec = tween(180),
                        label = "alpha",
                    )

                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .clickable(
                                interactionSource = interactionSource,
                                indication = null,
                            ) { onSelect(entry.route) }
                            .padding(vertical = 2.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text(
                            text = entry.glyph,
                            modifier = Modifier.scale(scale),
                            color = if (active) C.signal else C.textDim,
                            fontSize = 20.sp,
                        )
                        Spacer(Modifier.height(1.dp))
                        Text(
                            text = entry.label,
                            modifier = Modifier.graphicsLayer { alpha = labelAlpha },
                            style = GsText.navItem.copy(
                                fontSize = 9.sp,
                                letterSpacing = 0.02.sp,
                            ),
                            color = if (active) C.bone else C.textFaint,
                            maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}
