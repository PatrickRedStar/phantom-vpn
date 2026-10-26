package com.ghoststream.vpn.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FullTunnelRoutesTest {
    private val routes = fullTunnelRoutes()

    private fun inTunnel(ip: String): Boolean {
        val v = ipToLong(ip)!!
        return routes.any { (addr, prefix) ->
            val base = ipToLong(addr)!!
            v >= base && v <= base + (1L shl (32 - prefix)) - 1
        }
    }

    @Test
    fun publicInternetRidesTheTunnel() {
        for (ip in listOf("1.0.0.1", "8.8.8.8", "89.110.109.128", "158.160.135.140", "223.255.255.255")) {
            assertTrue(ip, inTunnel(ip))
        }
    }

    @Test
    fun lanLinkLocalAndMulticastStayLocal() {
        for (ip in listOf("192.168.1.1", "10.0.0.1", "172.16.5.5", "169.254.1.1", "224.0.0.251", "100.64.0.1")) {
            assertFalse(ip, inTunnel(ip))
        }
    }

    @Test
    fun routeTableStaysSmall() {
        assertTrue("${routes.size} routes", routes.size < 64)
    }

    @Test
    fun specialAddressesAreRecognised() {
        assertTrue(isSpecialAddress("192.168.0.1"))
        assertFalse(isSpecialAddress("8.8.8.8"))
        assertFalse(isSpecialAddress("2001:4860:4860::8888"))
    }
}
