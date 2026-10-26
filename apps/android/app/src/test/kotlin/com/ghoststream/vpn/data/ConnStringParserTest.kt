package com.ghoststream.vpn.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.Base64

/** Same link shape as client-common::parse_conn_string; padding is tolerated only here. */
class ConnStringParserTest {

    private val cert = "-----BEGIN CERTIFICATE-----\nMIIBcert\n-----END CERTIFICATE-----"
    private val key = "-----BEGIN PRIVATE KEY-----\nMIIBkey\n-----END PRIVATE KEY-----"
    private val pem = "$cert\n$key\n"

    private fun link(userinfo: String, query: String = "sni=tls.example.com&tun=10.7.0.5%2F24&v=1") =
        "ghs://$userinfo@1.2.3.4:443?$query"

    private val noPad = Base64.getUrlEncoder().withoutPadding().encodeToString(pem.toByteArray())
    private val padded = Base64.getUrlEncoder().encodeToString(pem.toByteArray())

    @Test
    fun parsesUnpaddedLink() {
        val cfg = ConnStringParser.parse(link(noPad)).getOrThrow()
        assertEquals("1.2.3.4:443", cfg.addr)
        assertEquals("tls.example.com", cfg.sni)
        assertEquals("10.7.0.5/24", cfg.tun)
        assertEquals(cert, cfg.cert)
        assertEquals(key, cfg.key)
    }

    @Test
    fun paddingIsOptional() {
        assertNotEquals("vector must actually need padding", noPad, padded)
        assertEquals(
            ConnStringParser.parse(link(noPad)).getOrThrow(),
            ConnStringParser.parse(link(padded)).getOrThrow(),
        )
    }

    @Test
    fun paddingInTheMiddleIsRejected() {
        val broken = noPad.substring(0, 8) + "=" + noPad.substring(8)
        assertTrue(ConnStringParser.parse(link(broken)).isFailure)
    }

    @Test
    fun lineWrappedPasteStillParses() {
        val wrapped = noPad.chunked(20).joinToString("\n ")
        assertEquals(
            ConnStringParser.parse(link(noPad)).getOrThrow(),
            ConnStringParser.parse(link(wrapped)).getOrThrow(),
        )
    }

    @Test
    fun rejectsMissingTunAndWrongVersion() {
        assertTrue(ConnStringParser.parse(link(noPad, "sni=x&v=1")).isFailure)
        assertTrue(ConnStringParser.parse(link(noPad, "sni=x&tun=10.7.0.5%2F24&v=2")).isFailure)
        assertTrue(ConnStringParser.parse("not-a-link").isFailure)
    }

    @Test
    fun legacyInsecureParamIsIgnored() {
        val cfg = ConnStringParser.parse(link(noPad, "sni=tls.example.com&tun=10.7.0.5%2F24&v=1&insecure=1"))
            .getOrThrow()
        assertEquals("tls.example.com", cfg.sni)
    }

    @Test
    fun buildRoundTrips() {
        val dir = createTempDirectoryCompat()
        val certFile = File(dir, "client.crt").apply { writeText(cert + "\n") }
        val keyFile = File(dir, "client.key").apply { writeText(key + "\n") }
        val profile = VpnProfile(
            serverAddr = "1.2.3.4:443",
            serverName = "tls.example.com",
            certPath = certFile.path,
            keyPath = keyFile.path,
            tunAddr = "10.7.0.5/24",
        )
        val built = ConnStringParser.build(profile)!!
        assertEquals(ConnStringParser.parse(link(noPad)).getOrThrow(), ConnStringParser.parse(built).getOrThrow())
        dir.deleteRecursively()
    }

    private fun createTempDirectoryCompat(): File =
        File.createTempFile("gs-conn", "").apply { delete(); mkdirs() }
}
