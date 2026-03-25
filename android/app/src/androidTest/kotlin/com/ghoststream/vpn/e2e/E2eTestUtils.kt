package com.ghoststream.vpn.e2e

import androidx.compose.ui.test.ComposeUiTest
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until

@OptIn(ExperimentalTestApi::class)
fun ComposeUiTest.clickTag(tag: String) {
    onNodeWithTag(tag, useUnmergedTree = true).performScrollTo().performClick()
}

fun tapVpnPermissionIfShown(timeoutMs: Long = 3000) {
    val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
    val allowSelectors = listOf(
        By.res("com.android.vpndialogs", "button1"),
        By.res("android", "button1"),
        By.res("com.android.permissioncontroller", "permission_allow_button"),
        By.res("com.android.permissioncontroller", "permission_allow_foreground_only_button"),
        By.res("com.android.permissioncontroller", "permission_allow_one_time_button"),
        By.textContains("Разреш"),
        By.textContains("РАЗРЕШ"),
        By.textContains("Allow"),
        By.textContains("ALLOW"),
        By.textContains("Продолж"),
        By.textContains("CONTINUE"),
        By.textContains("ОК"),
        By.textContains("OK"),
    )
    for (selector in allowSelectors) {
        val obj = device.wait(Until.findObject(selector), timeoutMs)
        if (obj != null) {
            obj.click()
            return
        }
    }
}
