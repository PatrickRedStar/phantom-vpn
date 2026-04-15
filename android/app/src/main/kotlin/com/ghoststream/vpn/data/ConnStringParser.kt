package com.ghoststream.vpn.data

import android.util.Base64
import java.io.File
import java.net.URLDecoder
import java.net.URLEncoder

object ConnStringParser {

    data class ParsedConfig(
        val addr: String,
        val sni: String,
        val tun: String,
        val cert: String,
        val key: String,
        val transport: String = "h2",
    )

    /**
     * ghs://<base64url(cert_pem + "\n" + key_pem)>@<host>:<port>?sni=<sni>&tun=<cidr>&v=1
     */
    fun parse(input: String): Result<ParsedConfig> = runCatching {
        val trimmed = input.trim()
        require(trimmed.startsWith("ghs://")) {
            "Unsupported conn_string format: regenerate link via bot (expected 'ghs://…')"
        }
        val rest = trimmed.removePrefix("ghs://")

        val atIdx = rest.indexOf('@')
        require(atIdx > 0) { "Malformed ghs:// URL: missing '@'" }
        val userinfo = rest.substring(0, atIdx)
        val afterAt = rest.substring(atIdx + 1)

        val qIdx = afterAt.indexOf('?')
        require(qIdx > 0) { "Malformed ghs:// URL: missing query string" }
        val authority = afterAt.substring(0, qIdx)
        val query = afterAt.substring(qIdx + 1)

        require(userinfo.isNotEmpty()) { "Malformed ghs:// URL: empty userinfo" }
        require(authority.isNotEmpty()) { "Malformed ghs:// URL: empty host:port" }

        val padded = userinfo + "=".repeat((4 - userinfo.length % 4) % 4)
        val pemBytes = Base64.decode(padded, Base64.URL_SAFE or Base64.NO_WRAP)
        val pemStr = String(pemBytes, Charsets.UTF_8)

        val begins = Regex("-----BEGIN").findAll(pemStr).map { it.range.first }.toList()
        require(begins.size == 2) {
            "Expected 2 PEM blocks (cert + key) in userinfo, found ${begins.size}"
        }
        val first = pemStr.substring(begins[0], begins[1]).trim()
        val second = pemStr.substring(begins[1]).trim()
        val (certPem, keyPem) = if (first.contains("CERTIFICATE")) first to second else second to first
        require(certPem.contains("CERTIFICATE")) { "No CERTIFICATE PEM block found" }
        require(keyPem.contains("PRIVATE KEY")) { "No PRIVATE KEY PEM block found" }

        var sni: String? = null
        var tun: String? = null
        var version: String? = null
        var transport = "h2"
        for (pair in query.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            val k = if (eq >= 0) pair.substring(0, eq) else pair
            val vEnc = if (eq >= 0) pair.substring(eq + 1) else ""
            val v = URLDecoder.decode(vEnc, "UTF-8")
            when (k) {
                "sni" -> sni = v
                "tun" -> tun = v
                "v" -> version = v
                "transport" -> transport = v
            }
        }
        require(!sni.isNullOrEmpty()) { "Missing 'sni' query param" }
        require(!tun.isNullOrEmpty()) { "Missing 'tun' query param" }
        require(version == "1") { "Unsupported ghs:// version: $version" }

        ParsedConfig(
            addr = authority,
            sni = sni!!,
            tun = tun!!,
            cert = certPem,
            key = keyPem,
            transport = transport,
        )
    }

    /**
     * Rebuild a ghs:// URL from a stored profile. Reads cert/key files.
     */
    fun build(profile: VpnProfile): String? = runCatching {
        val cert = File(profile.certPath).readText().trimEnd()
        val key = File(profile.keyPath).readText().trim()
        val pem = "$cert\n$key"
        val userinfo = Base64.encodeToString(
            pem.toByteArray(Charsets.UTF_8),
            Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING,
        )
        val sni = URLEncoder.encode(profile.serverName, "UTF-8")
        val tun = URLEncoder.encode(profile.tunAddr, "UTF-8")
        "ghs://$userinfo@${profile.serverAddr}?sni=$sni&tun=$tun&v=1"
    }.getOrNull()
}
