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
        // v0.27.0: Android `Base64.URL_SAFE` lenient — silently ignores embedded
        // whitespace and realigns subsequent bytes, corrupting the inner PEM
        // body without raising any error at the userinfo level. Surfaces later
        // as `InvalidTrailingPadding` from rustls-pemfile when it tries to
        // decode the cert-block base64. Strip everything that isn't valid
        // base64url BEFORE the decode so a stray newline/space from a copy-paste
        // mishap can't corrupt the cert.
        val userinfo = rest.substring(0, atIdx).filter { c ->
            c == '-' || c == '_' || c == '=' || c in 'A'..'Z' || c in 'a'..'z' || c in '0'..'9'
        }
        val afterAt = rest.substring(atIdx + 1)

        val qIdx = afterAt.indexOf('?')
        require(qIdx > 0) { "Malformed ghs:// URL: missing query string" }
        val authority = afterAt.substring(0, qIdx)
        val query = afterAt.substring(qIdx + 1)

        require(userinfo.isNotEmpty()) { "Malformed ghs:// URL: empty userinfo" }
        require(authority.isNotEmpty()) { "Malformed ghs:// URL: empty host:port" }

        // v0.25.0: cap userinfo at 16 KB. Real PEM cert+key for RSA-4096 is
        // ~5-7 KB base64; pasting a 10 MB blob from clipboard would OOM on
        // low-end devices. 16 KB gives 2× headroom.
        require(userinfo.length <= 16_384) {
            "conn_string userinfo too large (${userinfo.length} > 16384)"
        }

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
        val base = "ghs://$userinfo@${profile.serverAddr}?sni=$sni&tun=$tun&v=1"
        // v0.27.0 (W12): forward profile.insecure into conn_string. Without
        // this the Rust client always sees insecure=false (parse_conn_string
        // doesn't keep the toggle in state otherwise), and SNI overrides like
        // www.yandex.cloud fail hostname verification at the rustls layer.
        if (profile.insecure) "$base&insecure=1" else base
    }.getOrNull()
}
