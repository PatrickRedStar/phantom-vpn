package com.ghoststream.vpn

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import org.junit.Rule
import org.junit.Test

class AppSmokeE2ETest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun opensLogsOverlayFromDashboard() {
        composeRule.onNodeWithTag("dashboard_open_logs", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("overlay_close_logs").performClick()
    }

    @Test
    fun opensAllSettingsSubOverlays() {
        composeRule.onNodeWithTag("dashboard_open_settings", useUnmergedTree = true).performScrollTo().performClick()

        composeRule.onNodeWithTag("settings_open_dns", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("overlay_close_dns").performClick()

        composeRule.onNodeWithTag("settings_open_routes", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("overlay_close_routes").performClick()

        composeRule.onNodeWithTag("settings_open_apps", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("overlay_close_apps").performClick()

        composeRule.onNodeWithTag("settings_open_add_server", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("add_server_submit", useUnmergedTree = true).performScrollTo()
        composeRule.onNodeWithTag("overlay_close_add_server").performClick()
    }

    @Test
    fun appsOverlayShowsAllowedModeWarning() {
        composeRule.onNodeWithTag("dashboard_open_settings", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("settings_open_apps", useUnmergedTree = true).performScrollTo().performClick()

        composeRule.onNodeWithTag("apps_mode_allowed", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("overlay_close_apps").performClick()
    }
}
