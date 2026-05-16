package com.ghoststream.vpn.ui.components

import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalConfiguration

/**
 * Pick the navigation chrome (Bar / Rail / Drawer) based on **physical form
 * factor**, not just the current window width.
 *
 * Why this exists rather than using
 * `NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo` directly:
 *  - The Material default switches to Rail at width ≥ 600 dp. A phone
 *    rotated to landscape (~870 dp wide, but `smallestScreenWidthDp` ≈ 412)
 *    would jump to a side rail. Awful UX for phones — Pixel/Samsung phones
 *    in landscape should keep the floating bottom capsule.
 *  - `smallestScreenWidthDp` is invariant under rotation. It reports the
 *    shortest side of the device's physical screen, so it's a reliable
 *    "this is actually a tablet / unfolded foldable" signal.
 *
 * Breakpoints (v0.26.0):
 *  - `sw < 600`               → NavigationBar (phone, any orientation)
 *  - `sw ≥ 600, width < 840`  → NavigationRail (small tablet / unfolded fold)
 *  - `sw ≥ 600, width ≥ 840`  → NavigationDrawer (Tab S11 in landscape,
 *                                  large foldables open in landscape)
 *
 * Spec: docs/superpowers/specs/2026-05-16-tablet-layout-design.md §1.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun rememberAdaptiveNavType(): NavigationSuiteType {
    val configuration = LocalConfiguration.current
    val smallestWidthDp = configuration.smallestScreenWidthDp
    val currentWidthDp = configuration.screenWidthDp

    return remember(smallestWidthDp, currentWidthDp) {
        when {
            smallestWidthDp >= 600 && currentWidthDp >= 840 ->
                NavigationSuiteType.NavigationDrawer
            smallestWidthDp >= 600 ->
                NavigationSuiteType.NavigationRail
            else ->
                NavigationSuiteType.NavigationBar
        }
    }
}
