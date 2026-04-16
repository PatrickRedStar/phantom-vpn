package com.ghoststream.vpn.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.em
import androidx.compose.ui.unit.sp
import com.ghoststream.vpn.R

// ── Font families ───────────────────────────────────────────────────────────

val InstrumentSerif = FontFamily(
    Font(R.font.instrument_serif, FontWeight.Normal, FontStyle.Normal),
    Font(R.font.instrument_serif_italic, FontWeight.Normal, FontStyle.Italic),
)

val SpaceGrotesk = FontFamily(
    Font(R.font.space_grotesk, FontWeight.Normal),
    Font(R.font.space_grotesk_bold, FontWeight.Bold),
)

val DepartureMono = FontFamily(
    Font(R.font.departure_mono, FontWeight.Normal),
)

val JetBrainsMono = FontFamily(
    Font(R.font.jetbrains_mono, FontWeight.Normal),
    Font(R.font.jetbrains_mono_medium, FontWeight.Medium),
)

// ── Named text styles (used directly, bypassing MaterialTheme.typography) ───

object GsText {
    // Big brand / hero text — Space Grotesk bold.
    val brand = TextStyle(
        fontFamily = SpaceGrotesk,
        fontWeight = FontWeight.Bold,
        fontSize = 22.sp,
        letterSpacing = (-0.02).em,
    )
    val specTitle = TextStyle(
        fontFamily = SpaceGrotesk,
        fontWeight = FontWeight.Bold,
        fontSize = 42.sp,
        letterSpacing = (-0.02).em,
    )
    val stateHeadline = TextStyle(
        fontFamily = SpaceGrotesk,
        fontWeight = FontWeight.Bold,
        fontSize = 54.sp,
        lineHeight = 56.sp,
        letterSpacing = (-0.035).em,
    )
    val profileName = TextStyle(
        fontFamily = SpaceGrotesk,
        fontWeight = FontWeight.Bold,
        fontSize = 18.sp,
        letterSpacing = (-0.01).em,
    )
    val clientName = TextStyle(
        fontFamily = SpaceGrotesk,
        fontWeight = FontWeight.Bold,
        fontSize = 17.sp,
        letterSpacing = (-0.01).em,
    )
    val statValue = TextStyle(
        fontFamily = SpaceGrotesk,
        fontWeight = FontWeight.Bold,
        fontSize = 24.sp,
        lineHeight = 24.sp,
        letterSpacing = (-0.01).em,
    )
    val hint = TextStyle(
        fontFamily = SpaceGrotesk,
        fontWeight = FontWeight.Normal,
        fontSize = 22.sp,
        letterSpacing = (-0.01).em,
    )

    // Departure Mono — ALL CAPS labels, tickers, numeric strips.
    val labelMono = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 9.5.sp,
        letterSpacing = 0.22.em,
    )
    val labelMonoSmall = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 9.sp,
        letterSpacing = 0.18.em,
    )
    val labelMonoTiny = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 8.5.sp,
        letterSpacing = 0.16.em,
    )
    val hdrMeta = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 9.5.sp,
        letterSpacing = 0.14.em,
    )
    val ticker = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 26.sp,
        letterSpacing = 0.04.em,
    )
    val valueMono = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 10.sp,
        letterSpacing = 0.08.em,
    )
    val chipText = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 9.5.sp,
        letterSpacing = 0.14.em,
    )
    val navItem = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 9.sp,
        letterSpacing = 0.16.em,
    )
    val fabText = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 11.sp,
        letterSpacing = 0.2.em,
        fontWeight = FontWeight.Medium,
    )

    // JetBrains Mono — body text, logs, addresses.
    val body = TextStyle(
        fontFamily = JetBrainsMono,
        fontWeight = FontWeight.Normal,
        fontSize = 12.sp,
    )
    val bodyMedium = TextStyle(
        fontFamily = JetBrainsMono,
        fontWeight = FontWeight.Normal,
        fontSize = 11.5.sp,
    )
    val kvValue = TextStyle(
        fontFamily = JetBrainsMono,
        fontWeight = FontWeight.Normal,
        fontSize = 11.sp,
    )
    val host = TextStyle(
        fontFamily = JetBrainsMono,
        fontWeight = FontWeight.Normal,
        fontSize = 10.sp,
    )
    val logTs = TextStyle(
        fontFamily = JetBrainsMono,
        fontSize = 9.sp,
    )
    val logLevel = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 8.5.sp,
        letterSpacing = 0.12.em,
    )
    val logMsg = TextStyle(
        fontFamily = JetBrainsMono,
        fontSize = 10.5.sp,
        lineHeight = 16.sp,
    )
}

// Baseline Material typography — everything maps to JetBrains Mono + text colour.
val GsTypography = Typography(
    bodyLarge   = TextStyle(fontFamily = JetBrainsMono, fontSize = 14.sp),
    bodyMedium  = TextStyle(fontFamily = JetBrainsMono, fontSize = 12.sp),
    bodySmall   = TextStyle(fontFamily = JetBrainsMono, fontSize = 11.sp),
    titleLarge  = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Bold, fontSize = 22.sp),
    titleMedium = TextStyle(fontFamily = SpaceGrotesk, fontWeight = FontWeight.Bold, fontSize = 17.sp),
    titleSmall  = TextStyle(fontFamily = DepartureMono, fontSize = 10.sp, letterSpacing = 0.18.em),
    labelLarge  = TextStyle(fontFamily = DepartureMono, fontSize = 10.sp, letterSpacing = 0.18.em),
    labelMedium = TextStyle(fontFamily = DepartureMono, fontSize = 9.5.sp, letterSpacing = 0.16.em),
    labelSmall  = TextStyle(fontFamily = DepartureMono, fontSize = 8.5.sp, letterSpacing = 0.14.em),
)
