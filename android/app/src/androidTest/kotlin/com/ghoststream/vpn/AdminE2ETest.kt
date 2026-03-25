package com.ghoststream.vpn

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextClearance
import androidx.compose.ui.test.performTextInput
import androidx.test.platform.app.InstrumentationRegistry
import com.ghoststream.vpn.e2e.E2eProfileLoader
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import java.util.Locale

class AdminE2ETest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun adminCreateAndDeleteClientFlow() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val seeded = E2eProfileLoader.seedFromInstrumentationArgsOrNull(context)
        assumeTrue("Missing e2e_profile_b64 profile argument", seeded != null)
        E2eProfileLoader.resetProfilesStoreSingleton()
        composeRule.activityRule.scenario.recreate()

        composeRule.onNodeWithTag("dashboard_open_settings", useUnmergedTree = true).performScrollTo().performClick()

        val adminButtons = composeRule.onAllNodesWithTag("profile_admin", useUnmergedTree = true)
            .fetchSemanticsNodes()
        assumeTrue("No profile with admin credentials", adminButtons.isNotEmpty())
        composeRule.onAllNodesWithTag("profile_admin", useUnmergedTree = true)[0].performClick()

        composeRule.onNodeWithTag("admin_fab_add_client", useUnmergedTree = true).performClick()

        val clientName = "e2e-${System.currentTimeMillis()}"
        val suffix = clientName.lowercase(Locale.getDefault()).replace(" ", "_")

        composeRule.onNodeWithTag("admin_add_client_name_input", useUnmergedTree = true)
            .performTextClearance()
        composeRule.onNodeWithTag("admin_add_client_name_input", useUnmergedTree = true)
            .performTextInput(clientName)
        composeRule.onNodeWithTag("admin_add_client_confirm", useUnmergedTree = true).performClick()

        composeRule.waitUntil(30_000) {
            composeRule.onAllNodesWithText(clientName, useUnmergedTree = true)
                .fetchSemanticsNodes().isNotEmpty()
        }

        // open conn string dialog for created client
        composeRule.onNodeWithTag("admin_client_connstring_$suffix", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithText("Закрыть", useUnmergedTree = true).performClick()

        // cleanup: delete created client
        composeRule.onNodeWithTag("admin_client_delete_$suffix", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithText("Удалить", useUnmergedTree = true).performClick()
    }
}
