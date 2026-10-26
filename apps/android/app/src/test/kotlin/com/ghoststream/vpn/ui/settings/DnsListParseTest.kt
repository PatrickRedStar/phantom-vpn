package com.ghoststream.vpn.ui.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DnsListParseTest {

    @Test
    fun acceptsCommaSemicolonAndSpaces() {
        assertEquals(
            listOf("1.1.1.1", "8.8.8.8", "9.9.9.9"),
            SettingsViewModel.parseDnsList(" 1.1.1.1, 8.8.8.8;9.9.9.9 ; 1.1.1.1"),
        )
    }

    @Test
    fun rejectsEmptyAndInvalid() {
        assertNull(SettingsViewModel.parseDnsList(""))
        assertNull(SettingsViewModel.parseDnsList(" ,; "))
        assertNull(SettingsViewModel.parseDnsList("1.1.1.1, 999.1.1.1"))
        assertNull(SettingsViewModel.parseDnsList("1.1.1.1, dns.google"))
        assertNull(SettingsViewModel.parseDnsList("1.1.1"))
    }
}
