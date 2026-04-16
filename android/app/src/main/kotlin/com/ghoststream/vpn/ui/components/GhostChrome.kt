package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.SpaceGrotesk

/** Screen header used on every Ghoststream screen. Brand (italic serif, G tinted lime)
 *  + right-aligned departure-mono meta, hairline-separated from body. */
@Composable
fun ScreenHeader(
    brand: String,
    meta: (@Composable () -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .hairlineBottom()
            .padding(horizontal = 22.dp)
            .padding(top = 22.dp, bottom = 14.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(
            text = tintFirstLetter(brand, C.signal),
            style = com.ghoststream.vpn.ui.theme.GsText.brand,
            color = C.bone,
        )
        if (meta != null) meta()
    }
}

/** Meta block — pulse-dot + caps mono text (used in header right side). */
@Composable
fun HeaderMeta(
    text: String,
    pulse: Boolean = false,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        if (pulse) {
            PulseDot()
            Spacer(Modifier.width(6.dp))
        }
        Text(
            text = text.uppercase(),
            style = com.ghoststream.vpn.ui.theme.GsText.hdrMeta,
            color = C.textFaint,
        )
    }
}

/** Builds AnnotatedString with the first letter tinted with the given color. */
fun tintFirstLetter(text: String, color: Color): AnnotatedString = buildAnnotatedString {
    if (text.isEmpty()) return@buildAnnotatedString
    withStyle(SpanStyle(color = color)) { append(text.first()) }
    if (text.length > 1) append(text.substring(1))
}

/** Builds "<verb-lime>.<" — e.g. «Transmitting.» where only «Transmitting» is lime. */
fun serifAccent(verb: String, tail: String, accent: Color): AnnotatedString = buildAnnotatedString {
    withStyle(SpanStyle(color = accent)) { append(verb) }
    append(tail)
}
