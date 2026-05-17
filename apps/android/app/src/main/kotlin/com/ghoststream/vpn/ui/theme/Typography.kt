package com.ghoststream.vpn.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalConfiguration
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
    // v0.26.1: responsive по WindowSizeClass. Phone хороший, но на Tab S11
    // 54sp выглядит карликом в huge headline pane — масштабируется по форм-
    // фактору. lineHeight держим proportional (≈ 1.063× от fontSize, как в
    // оригинале 54/56).
    //   Compact (phone, sw < 600)              → 54sp / 56sp
    //   Medium  (tablet portrait, sw ≥ 600,     → 56sp / 60sp
    //            current width < 840)
    //   Expanded (tablet landscape / unfolded,  → 64sp / 68sp
    //            sw ≥ 600 ∧ width ≥ 840)
    //
    // v0.26.4 down-tuned: на Tab S11 landscape 80sp ломает одну строку для
    // "Переподключаемся 1/8…" (15 chars + ellipsis) в 42% pane (~445 dp).
    // 64sp гарантированно fits + строит чище визуальный rhythm с timer
    // ticker'ом 26sp снизу. Medium portrait тоже понижен до 56sp — на 10"
    // portrait 72sp слишком doминирует над остальной телеметрией. Compact
    // (phone) не трогаем — там пропорции уже выверены.
    val stateHeadline: TextStyle
        @Composable get() {
            val cfg = LocalConfiguration.current
            val (fs, lh) = when {
                cfg.smallestScreenWidthDp >= 600 && cfg.screenWidthDp >= 840 ->
                    64.sp to 68.sp
                cfg.smallestScreenWidthDp >= 600 ->
                    56.sp to 60.sp
                else ->
                    54.sp to 56.sp
            }
            return TextStyle(
                fontFamily = SpaceGrotesk,
                fontWeight = FontWeight.Bold,
                fontSize = fs,
                lineHeight = lh,
                letterSpacing = (-0.035).em,
            )
        }
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
        fontSize = 10.5.sp,
        letterSpacing = 0.18.em,
    )
    val labelMonoSmall = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 10.sp,
        letterSpacing = 0.15.em,
    )
    val labelMonoTiny = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 9.5.sp,
        letterSpacing = 0.14.em,
    )
    val hdrMeta = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 10.5.sp,
        letterSpacing = 0.12.em,
    )
    val ticker = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 26.sp,
        letterSpacing = 0.04.em,
    )
    val valueMono = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 11.sp,
        letterSpacing = 0.08.em,
    )
    val chipText = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 10.5.sp,
        letterSpacing = 0.12.em,
    )
    val navItem = TextStyle(
        fontFamily = DepartureMono,
        fontSize = 10.sp,
        letterSpacing = 0.14.em,
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
        fontSize = 9.5.sp,
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
    titleSmall  = TextStyle(fontFamily = DepartureMono, fontSize = 11.sp, letterSpacing = 0.15.em),
    labelLarge  = TextStyle(fontFamily = DepartureMono, fontSize = 11.sp, letterSpacing = 0.15.em),
    labelMedium = TextStyle(fontFamily = DepartureMono, fontSize = 10.5.sp, letterSpacing = 0.14.em),
    labelSmall  = TextStyle(fontFamily = DepartureMono, fontSize = 9.5.sp, letterSpacing = 0.12.em),
)
