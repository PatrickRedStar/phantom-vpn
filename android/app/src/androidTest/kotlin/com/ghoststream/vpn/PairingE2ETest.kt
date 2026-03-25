package com.ghoststream.vpn

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import org.junit.Ignore
import org.junit.Rule
import org.junit.Test

class PairingE2ETest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    @Ignore("Flaky on OneUI when isolated; covered by AppSmokeE2ETest flow.")
    fun openQrScannerFromAddServerAndReturn() {
        composeRule.onNodeWithTag("dashboard_open_settings", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("settings_open_add_server", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("add_server_qr", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("qr_scanner_root", useUnmergedTree = true).performScrollTo()
        composeRule.onNodeWithTag("qr_scanner_back", useUnmergedTree = true).performClick()
    }
}
