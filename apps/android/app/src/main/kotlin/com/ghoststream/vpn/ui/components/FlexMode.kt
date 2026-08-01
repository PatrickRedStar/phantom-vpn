package com.ghoststream.vpn.ui.components

import android.app.Activity
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.produceState
import androidx.compose.ui.platform.LocalContext
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker

/**
 * Flex Mode (ADR 0015): tabletop-постура — устройство полусложено, шарнир
 * горизонтален (Fold/Flip стоит «уголком»). Раскладка делится шарниром:
 * верхняя половина — «экран» (что смотришь), нижняя — «пульт» (что трогаешь).
 *
 * Detection — только через [FoldingFeature]: размеры окна при полускладывании
 * не меняются, поэтому dp-пороги (AdaptiveInfo) эту позу не видят в принципе.
 *
 * @return доля высоты окна над шарниром (0.3..0.7) или null, если постура
 *   не tabletop. Долю считаем из bounds шарнира, чтобы контент не заезжал
 *   на сгиб на устройствах с несимметричным делением.
 */
@Composable
fun rememberTabletopHingeRatio(): State<Float?> {
    val context = LocalContext.current
    return produceState<Float?>(initialValue = null, context) {
        val activity = context as? Activity ?: return@produceState
        WindowInfoTracker.getOrCreate(activity)
            .windowLayoutInfo(activity)
            .collect { info ->
                val fold = info.displayFeatures
                    .filterIsInstance<FoldingFeature>()
                    .firstOrNull {
                        it.state == FoldingFeature.State.HALF_OPENED &&
                            it.orientation == FoldingFeature.Orientation.HORIZONTAL
                    }
                value = fold?.let {
                    val windowH = activity.window.decorView.height
                    if (windowH <= 0) null
                    else (it.bounds.top.toFloat() / windowH).coerceIn(0.3f, 0.7f)
                }
            }
    }
}
