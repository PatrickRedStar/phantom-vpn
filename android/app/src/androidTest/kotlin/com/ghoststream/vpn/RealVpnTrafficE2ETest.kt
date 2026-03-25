package com.ghoststream.vpn

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.platform.app.InstrumentationRegistry
import com.ghoststream.vpn.e2e.E2eProfileLoader
import com.ghoststream.vpn.e2e.E2eProfile
import com.ghoststream.vpn.e2e.tapVpnPermissionIfShown
import org.junit.Assume.assumeTrue
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.net.HttpURLConnection
import java.net.URL

class RealVpnTrafficE2ETest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    private fun hasText(text: String): Boolean = runCatching {
        composeRule.onAllNodesWithText(text, useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty()
    }.getOrDefault(false)

    @Test
    fun connectDisconnectAndTrafficAffectingToggles() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val seeded = E2eProfileLoader.seedFromInstrumentationArgsOrNull(context)
        assumeTrue("Missing e2e_profile_b64 profile argument", seeded != null)
        E2eProfileLoader.resetProfilesStoreSingleton()
        composeRule.activityRule.scenario.recreate()

        composeRule.onNodeWithTag("dashboard_open_settings", useUnmergedTree = true).performScrollTo().performClick()
        val hasProfiles = !hasText("Подключений пока нет. Добавьте новый хост или отсканируйте QR-код.")
        assumeTrue("No VPN profiles configured on device", hasProfiles)

        // Stabilize preconditions: disable split-routing and force all-app mode.
        if (hasText("SPLIT ON")) {
            composeRule.onNodeWithTag("settings_split_toggle", useUnmergedTree = true).performScrollTo().performClick()
        }
        composeRule.onNodeWithTag("settings_perapp_mode_none", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("overlay_close_settings").performClick()

        // If previous run left VPN connected, explicitly disconnect first.
        if (hasText("Подключён")) {
            composeRule.onNodeWithTag("dashboard_connect_toggle", useUnmergedTree = true).performClick()
            composeRule.waitUntil(30_000) { hasText("Отключён") || hasText("Ошибка") }
        }

        // Connect
        composeRule.onNodeWithTag("dashboard_connect_toggle", useUnmergedTree = true).performClick()
        tapVpnPermissionIfShown(10_000)
        assertTrue("Expected admin API reachable while VPN connected", waitUntilAdminReachable(seeded!!, 90_000))
        assertTrafficThroughVpn(seeded)

        // Disconnect
        composeRule.onNodeWithTag("dashboard_connect_toggle", useUnmergedTree = true).performClick()
        composeRule.waitUntil(30_000) { hasText("Отключён") || hasText("Ошибка") }
        assertTrue("Expected admin API to become unreachable after disconnect", waitUntilAdminUnreachable(seeded, 30_000))
        assertTrafficAfterDisconnect(seeded)

        // Split toggle affects routing -> reconnect cycle
        composeRule.onNodeWithTag("dashboard_open_settings", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("settings_split_toggle", useUnmergedTree = true).performScrollTo().performClick()
        composeRule.onNodeWithTag("overlay_close_settings").performClick()
        composeRule.onNodeWithTag("dashboard_connect_toggle", useUnmergedTree = true).performClick()
        tapVpnPermissionIfShown(10_000)
        assertTrue("Expected reconnect after split toggle", waitUntilAdminReachable(seeded, 90_000))
        composeRule.onNodeWithTag("dashboard_connect_toggle", useUnmergedTree = true).performClick()
    }

    private fun waitUntilAdminReachable(profile: E2eProfile, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (isAdminReachable(profile, connectTimeoutMs = 4000, readTimeoutMs = 4000)) return true
            Thread.sleep(1500)
        }
        return false
    }

    private fun waitUntilAdminUnreachable(profile: E2eProfile, timeoutMs: Long): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (!isAdminReachable(profile, connectTimeoutMs = 2500, readTimeoutMs = 2500)) return true
            Thread.sleep(1200)
        }
        return false
    }

    private fun isAdminReachable(profile: E2eProfile, connectTimeoutMs: Int, readTimeoutMs: Int): Boolean {
        val url = profile.adminUrl
        val token = profile.adminToken
        if (url.isNullOrBlank() || token.isNullOrBlank()) return false
        return runCatching {
            val conn = (URL("${url.trimEnd('/')}/api/status").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer $token")
                connectTimeout = connectTimeoutMs
                readTimeout = readTimeoutMs
            }
            val ok = conn.responseCode == 200
            conn.disconnect()
            ok
        }.getOrDefault(false)
    }

    private fun assertTrafficThroughVpn(profile: E2eProfile) {
        val url = profile.adminUrl
        val token = profile.adminToken
        if (url.isNullOrBlank() || token.isNullOrBlank()) return
        val reachable = runCatching {
            val conn = (URL("${url.trimEnd('/')}/api/status").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer $token")
                connectTimeout = 5000
                readTimeout = 5000
            }
            val ok = conn.responseCode == 200
            conn.disconnect()
            ok
        }.getOrDefault(false)
        assertTrue("Expected admin API reachable while VPN connected", reachable)
    }

    private fun assertTrafficAfterDisconnect(profile: E2eProfile) {
        val url = profile.adminUrl
        val token = profile.adminToken
        if (url.isNullOrBlank() || token.isNullOrBlank()) return
        val reachable = runCatching {
            val conn = (URL("${url.trimEnd('/')}/api/status").openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                setRequestProperty("Authorization", "Bearer $token")
                connectTimeout = 3000
                readTimeout = 3000
            }
            val ok = conn.responseCode == 200
            conn.disconnect()
            ok
        }.getOrDefault(false)
        assertFalse("Expected admin API NOT reachable after disconnect", reachable)
    }
}
