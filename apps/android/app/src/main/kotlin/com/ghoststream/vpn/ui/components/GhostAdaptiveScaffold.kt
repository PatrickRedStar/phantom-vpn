package com.ghoststream.vpn.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationDrawerItem
import androidx.compose.material3.NavigationDrawerItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.adaptive.ExperimentalMaterial3AdaptiveApi
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldLayout
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import com.ghoststream.vpn.BuildConfig
import com.ghoststream.vpn.ui.theme.C
import com.ghoststream.vpn.ui.theme.GsText
import com.ghoststream.vpn.ui.theme.LocalIsDark

/**
 * Adaptive scaffold that switches the navigation chrome based on form factor.
 *
 * Compact (phone, any orientation):
 *   Renders only `content` — the caller's existing `GhostBottomNav` overlays
 *   the pager as before. We don't draw the bottom nav here so the floating
 *   capsule + gradient fade keeps its current visual relationship to the
 *   underlying content (it sits *on top of* the pager, not below it).
 *
 * Medium (small tablet / unfolded foldable):
 *   Left-side NavigationRail with ghoststream-styled items. Content fills
 *   the remaining width.
 *
 * Expanded (Tab S11 landscape, large foldables):
 *   Permanent left drawer (220 dp wide) with logo + items + version footer.
 *   Content fills the remaining width.
 *
 * The caller is responsible for hosting the pager / NavHost / status-bar
 * insets inside [content]. This composable only owns the navigation chrome.
 *
 * v0.26.0. Spec: docs/superpowers/specs/2026-05-16-tablet-layout-design.md §1.
 */
@OptIn(ExperimentalMaterial3AdaptiveApi::class)
@Composable
fun GhostAdaptiveScaffold(
    entries: List<NavEntry>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    navType: NavigationSuiteType,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    // Compact → no chrome here. Caller overlays GhostBottomNav itself.
    // This branch exists so we don't fight the existing phone UX.
    if (navType == NavigationSuiteType.NavigationBar) {
        Box(modifier) { content() }
        return
    }

    NavigationSuiteScaffoldLayout(
        layoutType = navType,
        navigationSuite = {
            when (navType) {
                NavigationSuiteType.NavigationRail ->
                    GhostNavigationRail(
                        entries = entries,
                        selectedIndex = selectedIndex,
                        onSelect = onSelect,
                    )
                NavigationSuiteType.NavigationDrawer ->
                    GhostPermanentDrawer(
                        entries = entries,
                        selectedIndex = selectedIndex,
                        onSelect = onSelect,
                    )
                else -> Unit // NavigationBar handled above; None = no chrome.
            }
        },
        content = {
            // .background(C.bg) defends against NavigationSuiteScaffoldLayout
            // consuming the navigationBars inset on tablet — the consumed
            // strip would otherwise expose the OS windowBackground.
            Box(Modifier.fillMaxSize().background(C.bg)) { content() }
        },
    )
}

/**
 * Left rail for Medium width tablets. Mono-cap labels in ghoststream palette,
 * lime tint on selection, no Material indicator bar (we let the icon+label
 * colour shift carry selection on its own).
 */
@Composable
private fun GhostNavigationRail(
    entries: List<NavEntry>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
) {
    // v0.26.4: theme-aware pill alpha. Lime on dark stays vivid at 0.10
    // because the phosphor signal is already saturated; moss-green on
    // light paper needs ~0.22 to read as a discernible pill against
    // C.bgElev. Without this, the active item is "almost invisible" on
    // light theme — the audit caught it on Tab S11 in daylight mode.
    val isDark = LocalIsDark.current
    val pillColor = C.signal.copy(alpha = if (isDark) 0.10f else 0.22f)
    NavigationRail(
        containerColor = C.bgElev,
        contentColor = C.bone,
        modifier = Modifier
            .fillMaxHeight()
            .windowInsetsPadding(WindowInsets.systemBars),
    ) {
        Spacer(Modifier.size(12.dp))
        entries.forEachIndexed { idx, entry ->
            val active = idx == selectedIndex
            NavigationRailItem(
                // v0.26.4: enforce 56 dp minimum touch target (Material a11y
                // guideline — Rail items are slightly larger than Bar/Drawer
                // because they carry both icon and label vertically).
                modifier = Modifier.heightIn(min = 56.dp),
                selected = active,
                onClick = { onSelect(idx) },
                icon = {
                    Icon(
                        painter = painterResource(id = entry.iconRes),
                        contentDescription = entry.label,
                        modifier = Modifier.size(22.dp),
                    )
                },
                label = {
                    Text(
                        text = entry.label.uppercase(),
                        style = GsText.labelMono,
                    )
                },
                alwaysShowLabel = true,
                colors = NavigationRailItemDefaults.colors(
                    selectedIconColor = C.signal,
                    unselectedIconColor = C.textDim,
                    selectedTextColor = C.bone,
                    unselectedTextColor = C.textFaint,
                    indicatorColor = pillColor,
                ),
            )
        }
    }
}

/**
 * Permanent left drawer for Expanded width tablets. Has the Ghoststream
 * wordmark at top, nav items in the middle, and a version footer at the
 * bottom.
 *
 * We use a Column inside a Box rather than `PermanentDrawerSheet` because
 * the latter brings Material3's own drawer container styling we don't want
 * to fight. A flat Column with our own background gives us exact pixel
 * control of padding and footer placement.
 */
@Composable
private fun GhostPermanentDrawer(
    entries: List<NavEntry>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
) {
    // v0.26.4: see GhostNavigationRail for rationale on theme-aware pill
    // alpha. Same fix here — the drawer's wider items make the under-saturated
    // pill on light theme even more glaring.
    val isDark = LocalIsDark.current
    val pillColor = C.signal.copy(alpha = if (isDark) 0.10f else 0.22f)
    Box(
        modifier = Modifier
            .fillMaxHeight()
            .width(220.dp)
            .background(C.bgElev)
            .windowInsetsPadding(WindowInsets.systemBars),
    ) {
        Column(Modifier.fillMaxSize()) {
            // Wordmark
            Text(
                text = "Ghoststream",
                style = GsText.brand,
                color = C.bone,
                modifier = Modifier.padding(
                    start = 22.dp,
                    top = 22.dp,
                    end = 14.dp,
                    bottom = 28.dp,
                ),
            )

            // Items
            entries.forEachIndexed { idx, entry ->
                val active = idx == selectedIndex
                NavigationDrawerItem(
                    selected = active,
                    onClick = { onSelect(idx) },
                    icon = {
                        Icon(
                            painter = painterResource(id = entry.iconRes),
                            contentDescription = entry.label,
                            modifier = Modifier.size(22.dp),
                        )
                    },
                    label = {
                        Text(
                            text = entry.label.uppercase(),
                            style = GsText.labelMono,
                        )
                    },
                    shape = RoundedCornerShape(10.dp),
                    colors = NavigationDrawerItemDefaults.colors(
                        selectedContainerColor = pillColor,
                        unselectedContainerColor = Color.Transparent,
                        selectedIconColor = C.signal,
                        unselectedIconColor = C.textDim,
                        selectedTextColor = C.bone,
                        unselectedTextColor = C.textFaint,
                    ),
                    // v0.26.4: enforce 48 dp minimum touch target (Material
                    // a11y guideline). NavigationDrawerItem's default height
                    // is 56 dp but with our reduced vertical padding (2 dp)
                    // the rendered hit-rect can dip below. heightIn is
                    // a no-op when default is already ≥ 48 — strictly a
                    // safety net.
                    modifier = Modifier
                        .padding(horizontal = 12.dp, vertical = 2.dp)
                        .heightIn(min = 48.dp),
                )
            }

            // Spacer pushes footer to the bottom.
            Spacer(Modifier.weight(1f))

            // Footer
            Text(
                text = "v${BuildConfig.VERSION_NAME}",
                style = GsText.labelMono,
                color = C.textFaint,
                modifier = Modifier.padding(start = 22.dp, bottom = 22.dp),
            )
        }
    }
}
